#!/usr/bin/env bash
# Pervio server-side regression suite. Runs every NO-COST test (shim agents, zero
# model calls) against the repo's server/bin scripts. One command:
#
#     bash server/tests/run_all.sh              # all no-cost suites
#     bash server/tests/run_all.sh --e2e        # also the real-agent e2e (spends a little quota)
#     bash server/tests/run_all.sh --live       # also the real-agent CONTRACT suite (Track B)
#     bash server/tests/run_all.sh --e2e --live # both paid layers
#     bash server/tests/run_all.sh --exclusive  # refuse to overlap another copy
#
# --live adds server/tests/test_agents_live.py: 8 real claude turns + 3 real codex
# turns, ~$0.50 of claude quota. It is the layer to run after upgrading claude or
# codex, alongside the corpus drift sentinel. Without --live that file is still
# invoked by nothing — it skips itself by default — so the free suite stays free.
#
# Exit 0 iff every suite passed. Each suite is hermetic (isolated $HOME / /tmp repos)
# and cleans up after itself.
#
# CONCURRENCY. Two copies of this script must be able to run at the same time and
# both come out green — that is a property of the suites, and it is asserted, not
# hoped for. It was NOT true on 2026-08-07, for three reasons, all now fixed at
# the source rather than serialized away:
#   * three suites drove pervio-orchestrate against the USER's ~/.pervio/wf, so
#     two runs shared a live state directory (and wrote a production path);
#   * test_view's J14 swept the machine with `pgrep -f sleeper.py`, which matches
#     the OTHER run's helper — a red that says nothing about the product;
#   * the efficiency suite timed whole runs with a stopwatch, so a busy box (i.e.
#     another copy of this script) pushed the wall clock past the bound while the
#     scheduler behaved perfectly. Those bounds now read the steps' own intervals.
# --exclusive is a fallback, deliberately OFF by default: an flock would make the
# suite pass by never overlapping, which hides exactly the regressions above. Use
# it when you want a clean stopwatch (E2's git-overhead number), not as a fix.
set -u
cd "$(dirname "$0")"
PY="${PYTHON:-python3}"
# A living run (pervio-run, 2026-10-20) stays warm 180 s after its reply for
# follow-ups; the suites want it gone in a second.
export PERVIO_RUN_IDLE_GRACE="${PERVIO_RUN_IDLE_GRACE:-1.5}"

e2e=0; live=0; exclusive=0
for a in "$@"; do
  case "$a" in
    --e2e)  e2e=1 ;;
    --live) live=1 ;;
    --exclusive) exclusive=1 ;;
    *) echo "run_all.sh: unknown flag: $a (expected --e2e, --live and/or --exclusive)" >&2; exit 2 ;;
  esac
done

if [ "$exclusive" -eq 1 ]; then
  LOCK="${TMPDIR:-/tmp}/pervio-run_all.lock"
  exec 9>"$LOCK"
  if command -v flock >/dev/null 2>&1; then
    flock 9 || { echo "run_all.sh: could not take $LOCK" >&2; exit 2; }
  elif command -v shlock >/dev/null 2>&1 || [ -x /usr/bin/shlock ]; then
    while ! /usr/bin/shlock -p $$ -f "$LOCK.pid"; do sleep 1; done
    trap 'rm -f "$LOCK.pid"' EXIT
  else
    echo "run_all.sh: --exclusive asked for, but neither flock nor shlock exists" >&2
    exit 2
  fi
fi

# No-cost suites (shim-driven), python.
SUITES=(
  "test_gateway.py"
  "test_provisioner_seeding.py"
  "test_conf_results.py"
  "test_install.py"
  "test_run.py"
  "test_group.py"              # pervio-group: rounds, synthesis, relay, finish hook, header strip
  "test_group_watch.py"        # pervio-group watch mode: pulse, finish look, verdicts, cap, approval hook
  "test_sessions.py"
  "test_ports.py"
  "test_codex_index.py"
  "test_upload.py"
  "test_approve.py"
  "test_chat.py"
  "test_provider.py"           # pervio-provider: vendor keys, Cursor key / file-store login, menu cut
  "test_dispatch.py"
  "test_fanout.py"
  "test_structured.py"
  "test_resume.py"
  "test_teststep.py"
  "test_schedule.py"
  "test_arxiv_shard.py"
  "test_digest_assemble.py"
  "test_push.py"
  "test_feedback.py"
  "test_view.py"
  "test_mcp.py"
  "test_orchestrate_unit.py"
  "test_orchestrate_security.py"
  "test_orchestrate_efficiency.py"
  "test_orchestrate_delete.py"
  "test_convergence.py"
  "test_event_corpus.py"
  "test_audit_fixes.py"
  "test_live_home.py"         # the real-agent suite's throwaway home really is one (free)
)

# No-cost suites written in bash. They need their own list rather than a hard-coded
# `bash test_term.sh` line, because the orphan gate below can only see a suite that
# is NAMED somewhere: with the shell suites invoked inline, a brand-new test_*.sh was
# invisible to the very gate that exists to catch it.
SHELL_SUITES=(
  "test_term.sh"              # pervio-term: arg parsing, ~/ expansion, private tmux socket
)

# The suites that deliberately live OUTSIDE the free layer, and why. Anything
# else under test_*.py or test_*.sh that is in none of these lists is an ORPHAN: a
# file that exists, is never run, and whose coverage is a claim nobody checks. That
# is exactly how test_orchestrate_delete.py and test_event_corpus.py sat outside this
# runner while ios/Tests/Fixtures/events/EVENTS.md told readers run_all.sh ran them.
OPT_IN=(
  "test_orchestrate_e2e.py"   # --e2e: real agents, spends quota
  "test_dispatch_e2e.py"      # --e2e: real agent-calls-agent, spends quota
  "test_fanout_e2e.py"        # --e2e: real per-item fan-out, spends quota
  "test_agents_live.py"       # --live: real agent contract suite, ~$0.50
)

# Committed-artifact freshness. Each entry re-derives, from the REAL server
# scripts, a file that is COMMITTED to the repo and read by the iOS test bundle,
# then diffs byte-for-byte. That is what keeps the frozen copies honest: a
# server-side change becomes a red HERE, instead of an iOS test that still passes
# against last month's bytes.
#
# Paths are relative to this directory, so a checker may live in the tree it
# freezes rather than beside the suites.
#
# They get a LIST, for the same reason SUITES has one: the gate below can only
# see a checker that is NAMED somewhere. make_actions_contract.py --check shipped
# with three separate promises that it was the thing catching server drift — its
# own docstring, and ios/Tests/Render/ReportActionContractTests.swift at :19 and
# :319 ("server drift turns `--check` red") — while nothing in the repo ran it.
# So pervio-view could move, add or drop a button group and BOTH screens stayed
# green: the phone kept agreeing with a frozen contract that had quietly expired.
CHECKERS=(
  "export_fixtures.py"                                    # iOS decoding fixtures
  "../../ios/Tests/Fixtures/reports/make_actions_contract.py"  # Mac button groups (spec B2)
)

# Does this script DECLARE a --check mode? Answered by PARSING it, never by
# running it and never by matching its source text.
#
# Both wrong answers have been tried here. A grep for the literal is blind to
# however the author happened to spell it — first only `"--check"`, so a
# single-quoted argparse walked past; then only single-line `add_argument(`, so
# `"--check" in sys.argv` walked past, which is exactly how this repo's oldest
# freezer (export_fixtures.py) declares it. Each time, "does this gate work" was
# really "did the author share my typing habits". Running the script instead is
# worse: it executed every .py in these trees TWICE, with the real HOME, no
# sandbox and no timeout — a support file wrote a real file merely by being
# interrogated — and it misread three ordinary shapes as freezers.
#
# The AST is the thing that means what it says. Two node shapes, both of which
# can only be a declaration, and neither of which a docstring or an assertion
# message can imitate:
#   add_argument(..., "--check", ...)   — the argparse form, any quote, wrapped
#   "--check" in sys.argv              — the hand-rolled form
_has_check_mode() {  # $1 = a .py to interrogate
  "$PY" - "$1" <<'PY'
import ast, sys
try:
    tree = ast.parse(open(sys.argv[1], encoding="utf-8", errors="replace").read())
except SyntaxError:
    sys.exit(1)          # can't parse it, won't accuse it
FLAG = "--check"
for n in ast.walk(tree):
    if (isinstance(n, ast.Call)
            and getattr(n.func, "attr", None) == "add_argument"
            and any(isinstance(a, ast.Constant) and a.value == FLAG for a in n.args)):
        sys.exit(0)
    if (isinstance(n, ast.Compare)
            and any(isinstance(o, ast.In) for o in n.ops)
            and isinstance(n.left, ast.Constant) and n.left.value == FLAG):
        sys.exit(0)
sys.exit(1)
PY
}

no_orphan_checkers() {
  # A generator that supports --check but that no layer runs is worse than having
  # none: its docstring, and the tests that cite it, keep claiming drift is
  # covered. Scan the trees that hold them and require membership in CHECKERS.
  #
  # test_*.py are deliberately skipped — they are the other gate's business.
  local orphans=() f rel
  for f in ./*.py ../../ios/Tests/Fixtures/reports/*.py; do
    [ -e "$f" ] || continue
    case "$f" in ./test_*.py) continue ;; esac
    rel="${f#./}"
    case " ${CHECKERS[*]} " in *" $rel "*) continue ;; esac
    _has_check_mode "$f" && orphans+=("$rel")
  done
  if [ "${#orphans[@]}" -ne 0 ]; then
    echo "FAIL a --check generator exists that no layer runs, so the artifact it"
    echo "     freezes can drift while everything stays green — add it to CHECKERS:"
    for f in "${orphans[@]}"; do echo "   - $f"; done
    return 1
  fi
  echo "PASS every --check generator is in CHECKERS (${#CHECKERS[@]} of them)"
  return 0
}

no_orphan_suites() {
  local orphans=() f
  # BOTH extensions: a suite's language is not a reason to stop counting it. The
  # `-e` guard is for the day a glob matches nothing and bash hands back the
  # pattern itself — that must not be reported as a missing suite.
  for f in test_*.py test_*.sh; do
    [ -e "$f" ] || continue
    case " ${SUITES[*]} ${SHELL_SUITES[*]} ${OPT_IN[*]} " in
      *" $f "*) ;;
      *) orphans+=("$f") ;;
    esac
  done
  if [ "${#orphans[@]}" -ne 0 ]; then
    echo "FAIL a test file exists that no layer runs — add it to SUITES/SHELL_SUITES,"
    echo "     or to OPT_IN with the reason it costs money:"
    for f in "${orphans[@]}"; do echo "   - $f"; done
    return 1
  fi
  echo "PASS every test_*.py and test_*.sh is either in a suite list or an explicit opt-in layer"
  return 0
}

pass=0; fail=0; failed_names=()

run_one() {  # $1 = human name, $2.. = command
  local name="$1"; shift
  echo ""
  echo "########################################################"
  echo "# $name"
  echo "########################################################"
  if "$@"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed_names+=("$name")
  fi
}

run_one "no orphan suites (every test file is in a layer)" no_orphan_suites
run_one "no orphan --check generators (every freezer is in CHECKERS)" no_orphan_checkers
for s in "${SHELL_SUITES[@]}"; do
  run_one "$s (bash)" bash "$s"
done
for s in "${SUITES[@]}"; do
  run_one "$s" "$PY" "$s"
done

# Freshness of every committed artifact (see CHECKERS above): re-derive it from
# the REAL scripts and fail if a single byte drifted.
for c in "${CHECKERS[@]}"; do
  run_one "$(basename "$c") --check (committed artifact still matches what the server renders)" \
          "$PY" "$c" --check
done

if [ "$e2e" -eq 1 ]; then
  run_one "test_orchestrate_e2e.py (REAL agents — spends quota)" "$PY" test_orchestrate_e2e.py
  run_one "test_dispatch_e2e.py (REAL agent-calls-agent — spends quota)" "$PY" test_dispatch_e2e.py
  run_one "test_fanout_e2e.py (REAL per-item fan-out — spends quota)" "$PY" test_fanout_e2e.py
fi

# Track B: the opt-in real-agent CONTRACT suite. Only under --live, and it prints
# its own per-scenario token/USD bill plus a total.
if [ "$live" -eq 1 ]; then
  run_one "test_agents_live.py (REAL agent contract suite — spends ~\$0.50)" \
          "$PY" test_agents_live.py --live
fi

echo ""
echo "========================================================"
if [ "$fail" -eq 0 ]; then
  echo "ALL SUITES PASSED ✅  ($pass suites)"
  exit 0
else
  echo "SUITE FAILURES ❌  ($pass passed, $fail failed)"
  for n in "${failed_names[@]}"; do echo "   - $n"; done
  exit 1
fi
