#!/usr/bin/env bash
# The release gate: one command for everything you must run before shipping.
# Plain-language version of what this covers: docs/test-plan.md.
#
#     bash scripts/test-release.sh              # everything free. NO model quota is spent.
#     bash scripts/test-release.sh --live       # ALSO the real-agent contract suite (SPENDS QUOTA)
#     bash scripts/test-release.sh --e2e        # ALSO the older real-agent e2e suites (SPENDS QUOTA)
#     bash scripts/test-release.sh --live --e2e # both paid layers, still ONE server pass
#     bash scripts/test-release.sh --plan       # what --live WOULD run and cost. Free.
#
# Exit 0 iff nothing failed. Layers: the script selftest, the iOS unit tests, the
# server suites, any FREE server suite run_all.sh has not adopted yet, the iOS UI
# smoke. --live / --e2e do NOT add a layer — they widen the server layer, because
# run_all.sh's paid suites are a superset of its free ones and running the free
# ones twice would just cost you three minutes.
#
# SKIP IS NOT PASS. A layer that could not run is SKIPPED, printed with its
# reason, and counted. For a release, insist on "0 failed, 0 skipped". Choosing
# not to spend money is NOT a skip — it is a choice, and it is reported as one.
#
# Same layer machinery and same two machine-readable last lines as test-fast.sh /
# test-all.sh (scripts/lib/layers.sh):
#
#     SUMMARY: 5 passed, 0 failed, 0 skipped
#     RESULT: PASS
#
# On top of that: a per-layer verdict table, and — whenever a paid layer ran —
# the token/USD bill it printed, quoted verbatim. The whole point of a layer that
# spends your money is that it tells you what it spent.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/layers.sh"

LIVE=0
E2E=0
PLAN=0
for a in "$@"; do
  case "$a" in
    --live) LIVE=1;;
    --e2e)  E2E=1;;
    --plan) PLAN=1;;
    # The whole leading comment block, whatever length it grows to — a hardcoded
    # line range silently truncates --help the first time this header is edited.
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown flag: $a" >&2; exit 2;;
  esac
done

LIVE_SUITE="$PERVIO_ROOT/server/tests/test_agents_live.py"
RUN_ALL="$PERVIO_ROOT/server/tests/run_all.sh"

# --plan: print the real-agent suite's own plan + cost model and stop. Free, and
# the honest way to decide whether you want to pay before you pay.
if [ "$PLAN" = 1 ]; then
  if [ ! -f "$LIVE_SUITE" ]; then
    echo "没有 $LIVE_SUITE —— 真 agent 契约套件还没装。" >&2; exit 2
  fi
  exec python3 "$LIVE_SUITE" --list
fi

# ---------------------------------------------------------------- honesty ---
# `run_all.sh --live` degrading into "just the free suites" and reporting PASS
# would be a green layer that tested nothing. Two independent checks:
#   BEFORE — the suite file exists and run_all.sh mentions the flag;
#   AFTER  — the suite's name actually appears in the output.
# Either one missing is said out loud instead of being absorbed into a pass.
live_unavailable_reason() {
  [ -f "$LIVE_SUITE" ] \
    || { echo "server/tests/test_agents_live.py not present (real-agent contract suite not installed)"; return 0; }
  grep -q -- '--live' "$RUN_ALL" 2>/dev/null \
    || { echo "server/tests/run_all.sh does not accept --live"; return 0; }
  return 1
}

# ------------------------------------------------------------------ layers ---
# The server layer, widened by whichever paid flags survived the checks above.
# One invocation, one log, one verdict.
SERVER_LAYER=server-suites
SERVER_LOG=""
LIVE_RAN=0        # "asked for" is not "ran"; the cost report may only claim the latter
E2E_RAN=0

layer_server() {
  local flags=() t0=$SECONDS rc reason
  if [ "$LIVE" = 1 ]; then
    if reason="$(live_unavailable_reason)"; then
      # Requested but impossible: a real gap, so a real (counted) SKIP line of
      # its own — the server layer below still runs, just without --live.
      skip_layer server-live-agents "$reason"
    else
      flags+=(--live); LIVE_RAN=1
    fi
  fi
  [ "$E2E" = 1 ] && { flags+=(--e2e); E2E_RAN=1; }

  [ "${#flags[@]}" -gt 0 ] && SERVER_LAYER=server-suites-quota
  SERVER_LOG="$LOG_DIR/$SERVER_LAYER.log"

  printf '\n########  %s  ########\n' "$SERVER_LAYER"
  if [ "${#flags[@]}" -gt 0 ]; then
    printf -- '-- REAL AGENTS: %s —— 这一层会花你的模型额度。\n' "${flags[*]}"
  fi
  bash "$RUN_ALL" "${flags[@]+"${flags[@]}"}" 2>&1 | tee "$SERVER_LOG"
  rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ]; then
    _fail=$((_fail+1)); _record "$SERVER_LAYER" FAIL "$((SECONDS-t0))" "exit $rc — $SERVER_LOG"
  elif [ "$LIVE_RAN" = 1 ] && ! grep -q 'test_agents_live' "$SERVER_LOG" 2>/dev/null; then
    _fail=$((_fail+1))
    _record "$SERVER_LAYER" FAIL "$((SECONDS-t0))" \
      "--live exited 0 but test_agents_live.py never ran — $SERVER_LOG"
    printf -- '-- FAILED: --live was accepted but test_agents_live.py never ran (see %s)\n' "$SERVER_LOG"
  else
    _pass=$((_pass+1)); _record "$SERVER_LAYER" PASS "$((SECONDS-t0))"
  fi
  return 0
}

# ------------------------------------------------------- orphaned suites ----
# A test file that no runner invokes is a test that does not exist. Two real,
# free suites are currently not in run_all.sh's SUITES list, and one of them
# guards the IRREVERSIBLE delete verbs — exactly what a release gate must not
# leave to "someone remembers to run it". So this layer runs whatever is
# orphaned, and self-heals: once run_all.sh picks a file up, we stop running it.
#
# The list is EXPLICIT and free-only on purpose. A glob would eventually sweep
# up a *_e2e / *_live file and spend your money by accident.
ORPHAN_CANDIDATES=(test_event_corpus.py test_orchestrate_delete.py)

# Does run_all.sh actually INVOKE this file? Comments are stripped first: a file
# merely named in a comment ("test_x.py is covered elsewhere") is not being run,
# and treating that as coverage would silently drop the suite from the gate.
_run_all_invokes() {
  grep -v '^[[:space:]]*#' "$RUN_ALL" 2>/dev/null | grep -q -- "$1"
}

_orphans() {  # echo the candidates that exist and run_all.sh does not invoke
  local f
  for f in "${ORPHAN_CANDIDATES[@]}"; do
    [ -f "$PERVIO_ROOT/server/tests/$f" ] || continue
    _run_all_invokes "$f" && continue
    printf '%s\n' "$f"
  done
}

# Detection only, never executed: any other server test file no runner mentions.
# Printed as a warning rather than run, because we cannot know whether a file we
# have never seen spends quota.
_warn_unknown_orphans() {
  local f base found=""
  for f in "$PERVIO_ROOT"/server/tests/test_*.py "$PERVIO_ROOT"/server/tests/test_*.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    _run_all_invokes "$base" && continue
    case " ${ORPHAN_CANDIDATES[*]} " in *" $base "*) continue;; esac
    # The paid suites are opt-in by design and run_all.sh does list them; this is
    # only for files nothing references at all.
    found="$found $base"
  done
  [ -n "$found" ] && printf -- '-- 注意:这些测试文件没有任何入口在跑,也不在本脚本的名单里:%s\n' "$found"
  return 0
}

_run_orphans() {
  local f rc=0
  for f in $(_orphans); do
    echo "### $f (run_all.sh 没收录,由发版关卡代跑)"
    python3 "$PERVIO_ROOT/server/tests/$f" || rc=1
  done
  return "$rc"
}

layer_orphan_suites() {
  local list
  list="$(_orphans)"
  _warn_unknown_orphans
  if [ -z "$list" ]; then
    echo "(没有游离的免费套件 —— run_all.sh 已经把它们都收录了)"
    return 0
  fi
  run_layer server-orphan-suites _run_orphans
  return 0
}

# ------------------------------------------------------------------- cost ----
# The live suite prints its own per-scenario token line and a total. We do not
# own that format, so scrape loosely and print VERBATIM what it said — inventing
# a number here would be worse than printing nothing.
cost_report() {
  local lines
  printf '\n----------------  真 agent 花费  ----------------\n'
  if [ "$LIVE_RAN" = 0 ] && [ "$E2E_RAN" = 0 ]; then
    if [ "$LIVE" = 1 ] || [ "$E2E" = 1 ]; then
      printf '  要求跑真 agent 层但它没跑起来(原因见上表的 SKIP),本次花费 0。\n'
    else
      printf '  本次没有跑真 agent 层,花费 0(要跑加 --live / --e2e;先看计划用 --plan)。\n'
    fi
  else
    # Loose on purpose: any line that mentions tokens/cost/spend AND has a digit.
    # Over-matching prints a couple of extra lines; under-matching would drop the
    # one number this section exists to show.
    lines="$(grep -iE 'token|cost|usd|花费|额度|spend' "$SERVER_LOG" 2>/dev/null \
             | grep -E '[0-9]' | tail -20)"
    if [ -n "$lines" ]; then
      printf '%s\n' "$lines" | sed 's/^/    /'
    else
      printf '  真 agent 层跑了,但输出里没找到带数字的花费行 —— 请翻日志:\n    %s\n' "$SERVER_LOG"
    fi
  fi
  printf -- '------------------------------------------------\n'
}

# -------------------------------------------------------------------- run ----

echo "pervio test-release — $(date '+%Y-%m-%d %H:%M:%S')  (logs: $LOG_DIR)"
if [ "$LIVE" = 1 ] || [ "$E2E" = 1 ]; then
  echo "模型额度:会花(--live=$LIVE --e2e=$E2E)"
else
  echo "模型额度:不花(要跑真 agent 层加 --live;想先看要花多少用 --plan)"
fi

layer_scripts_selftest

if [ "${PERVIO_SKIP_IOS:-0}" = 1 ]; then
  skip_layer ios-unit "PERVIO_SKIP_IOS=1"
else
  layer_ios_unit
fi

if [ "${PERVIO_SKIP_SERVER:-0}" = 1 ]; then
  skip_layer server-suites "PERVIO_SKIP_SERVER=1"
else
  layer_server
  layer_orphan_suites
fi

if [ "${PERVIO_SKIP_SMOKE:-0}" = 1 ]; then
  skip_layer ios-ui-smoke "PERVIO_SKIP_SMOKE=1"
else
  layer_ios_ui_smoke
fi

summary
rc=$?
cost_report
if [ "$rc" -ne 0 ]; then
  echo "发版关卡:红了 —— 上面 FAIL 那几行给了日志路径,先看日志尾部。"
elif [ "$_skip" -gt 0 ]; then
  # Exit 0 stays honest (nothing FAILED), but a release must not go out on a
  # layer that never ran, so say it in words and not only in the count.
  echo "发版关卡:没有失败,但有 $_skip 层没跑(上表 SKIP 那几行)。SKIP 不是 PASS ——"
  echo "  发版前请把它们清零:补上环境(模拟器/sshd)、去掉 PERVIO_SKIP_*。"
else
  echo "发版关卡:机器这关全过了。"
fi
echo "还得做的事:"
echo "  1. docs/test-plan.md 第四节的人工清单(锁屏/灵动岛/真机后台/排版),真机过一遍"
if [ "$LIVE_RAN" = 1 ]; then
  echo "  2. 真 agent 层这次跑了 —— 上面的花费那段就是它的账"
else
  echo "  2. 真 agent 层这次没跑 —— 发版前请跑一次 bash scripts/test-release.sh --live"
fi
exit "$rc"
