#!/usr/bin/env bash
# Shared machinery for scripts/test-fast.sh and scripts/test-all.sh.
#
# One idea: a "layer" is a named command whose exit code is recorded, whose
# output is streamed live AND kept in a log, and which can also honestly report
# "skipped" when its preconditions are absent. The summary has a fixed, greppable
# shape so the pre-push hook, the nightly job and scripts/tests/test_scripts.sh
# all read the same verdict:
#
#     SUMMARY: 2 passed, 1 failed, 0 skipped
#     RESULT: FAIL
#
# Sourced, never executed. Every knob has a default:
#   PERVIO_DESTINATION   xcodebuild -destination string (default: picked from simctl)
#   PERVIO_TEST_LOG_DIR  where per-layer logs land (default: $TMPDIR/pervio-test-logs/<pid>)
set -u

# Repo root derived from this file, so a copy of the tree (a git worktree, a test
# sandbox) tests itself rather than whichever checkout you happen to have open.
PERVIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# PER RUN, not per user. These logs stopped being something a human reads after
# the fact and became the VERDICT: `_ios_unit_test` greps ios-unit-xcodebuild.log
# to decide whether the transport tests really ran. A path shared by every run on
# the box means a second runner's `tee` truncates the file a first runner is
# about to read — and the first one then certifies itself with the second one's
# transcript. Reproduced 3/3: a run whose 17 security tests all skipped printed
# RESULT: PASS because the shared log held a concurrent run's passing lines.
# An explicit PERVIO_TEST_LOG_DIR is still honoured verbatim (callers that set it
# already own the uniqueness), but the default can no longer collide.
LOG_DIR="${PERVIO_TEST_LOG_DIR:-${TMPDIR:-/tmp}/pervio-test-logs/$$}"
mkdir -p "$LOG_DIR"

_names=(); _states=(); _notes=(); _secs=()
_pass=0; _fail=0; _skip=0; _unver=0

_record() { _names+=("$1"); _states+=("$2"); _secs+=("$3"); _notes+=("${4:-}"); }

# run_layer <name> <cmd...> — stream + log + record. Never aborts the run: a red
# layer must not hide the state of the layers after it.
run_layer() {
  local name="$1"; shift
  local log="$LOG_DIR/$name.log" t0=$SECONDS rc
  printf '\n########  %s  ########\n' "$name"
  # tee would otherwise donate ITS exit code to the layer; PIPESTATUS[0] is the
  # only thing here that tells the truth.
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    _pass=$((_pass+1)); _record "$name" PASS "$((SECONDS-t0))"
  else
    _fail=$((_fail+1)); _record "$name" FAIL "$((SECONDS-t0))" "exit $rc — $log"
  fi
  return "$rc"
}

# skip_layer <name> <reason> — the honest alternative to pretending a layer ran.
skip_layer() {
  printf '\n########  %s  ########\n-- SKIPPED: %s\n' "$1" "$2"
  _skip=$((_skip+1)); _record "$1" SKIP 0 "$2"
}

# fail_layer <name> <reason> — a layer that could not even start (no simulator,
# no project). Counted as red, because a layer that silently does not run is
# exactly the lie this whole file exists to prevent.
fail_layer() {
  printf '\n########  %s  ########\n-- FAILED: %s\n' "$1" "$2"
  _fail=$((_fail+1)); _record "$1" FAIL 0 "$2"
}

# unverified_layer <name> <secs> <reason> — the third honest verdict, and the one
# this file was missing. A layer is UNVERIFIED when it RAN, went green, and yet
# never exercised the thing it exists to prove: layer 1 on a machine with no
# sandbox sshd runs 188 tests, skips the 17 that hold host identity, and
# xcodebuild prints "** TEST SUCCEEDED **" over the top of them.
#
# PASS would be a lie, and SKIP would be a lie too — a skipped layer is one that
# did not run, and this one did. So it gets its own state, its own column in the
# summary and its own RESULT token, because the only consumer that matters here
# is a human or a hook grepping for "RESULT: PASS", and neither must ever see it.
unverified_layer() {
  _unver=$((_unver+1)); _record "$1" UNVER "$2" "$3"
}

# summary — the table plus the two machine-readable lines. Returns 1 iff a layer
# failed. Skips never fail the run; they are printed, counted, and named.
summary() {
  local i
  printf '\n========================================================\n'
  for i in "${!_names[@]}"; do
    printf '  %-16s %-5s %4ss  %s\n' "${_names[$i]}" "${_states[$i]}" "${_secs[$i]}" "${_notes[$i]}"
  done
  # The counts line only grows on the right, so every existing grep for
  # "SUMMARY: 2 passed, 0 failed, 0 skipped" still matches.
  printf 'SUMMARY: %d passed, %d failed, %d skipped' "$_pass" "$_fail" "$_skip"
  [ "$_unver" -gt 0 ] && printf ', %d unverified' "$_unver"
  printf '\n'
  local suffix=""
  [ "$_skip" -gt 0 ] && suffix=" ($_skip skipped)"
  if [ "$_fail" -gt 0 ]; then
    printf 'RESULT: FAIL%s\n' "$suffix"; return 1
  fi
  # Nothing failed, but something went green without proving anything. The token
  # is deliberately NOT "PASS": a hook, a nightly log or a person scanning for
  # that word has to come up empty.
  if [ "$_unver" -gt 0 ]; then
    printf 'RESULT: UNVERIFIED%s — %d layer(s) went green without exercising what they exist to prove\n' \
           "$suffix" "$_unver"
    return 0
  fi
  printf 'RESULT: PASS%s\n' "$suffix"; return 0
}

# ---------------------------------------------------------------------------
# Simulator selection. Xcode renames its stock device set every year ("iPhone 15
# Pro" → "iPhone 17 Pro"), so a hardcoded -destination is a script that dies on
# the next Xcode. Ask simctl instead: prefer an already-booted iPhone (fastest),
# then any available iPhone. Prints "<udid>|<name>"; commentary goes to stderr.
pick_simulator() {
  local list line udid name
  list="$(xcrun simctl list devices available 2>/dev/null)" || true
  line="$(printf '%s\n' "$list" | grep -E '^[[:space:]]+.*iPhone.*\(Booted\)' | head -1)"
  [ -z "$line" ] && line="$(printf '%s\n' "$list" | grep -E '^[[:space:]]+.*iPhone.*\(' | head -1)"
  udid="$(printf '%s' "$line" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
  if [ -z "$udid" ]; then
    echo "no iOS Simulator device available — 'xcrun simctl list devices available' lists no iPhone." >&2
    echo "Add one in Xcode > Settings > Components, or set PERVIO_DESTINATION yourself." >&2
    return 1
  fi
  name="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//; s/ \([0-9A-Fa-f-]{36}\).*$//')"
  printf '%s|%s\n' "$udid" "$name"
}

destination() {  # echoes the -destination value, or fails loudly
  if [ -n "${PERVIO_DESTINATION:-}" ]; then printf '%s\n' "$PERVIO_DESTINATION"; return 0; fi
  local picked; picked="$(pick_simulator)" || return 1
  echo "simulator: ${picked#*|} (${picked%%|*})" >&2
  printf 'platform=iOS Simulator,id=%s\n' "${picked%%|*}"
}

# XcodeGen output is gitignored (project.yml is the source of truth), so a fresh
# clone has no .xcodeproj at all. Regenerate when it is missing or older than the
# spec; otherwise leave it alone so an open Xcode isn't churned on every run.
ensure_project() {
  local proj="$PERVIO_ROOT/ios/Pervio.xcodeproj" spec="$PERVIO_ROOT/ios/project.yml"
  if [ ! -d "$proj" ] || [ "$spec" -nt "$proj" ]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
      echo "xcodegen not found and ios/Pervio.xcodeproj is missing or stale — brew install xcodegen" >&2
      return 1
    fi
    echo "xcodegen generate (project.yml is newer than the project)"
    ( cd "$PERVIO_ROOT/ios" && xcodegen generate ) || return 1
  fi
}

_xcodebuild_test() {  # $1 = -only-testing target, $2 = -destination
  local rc=0
  xcodebuild test \
    -project "$PERVIO_ROOT/ios/Pervio.xcodeproj" \
    -scheme Pervio \
    -destination "$2" \
    -derivedDataPath "$PERVIO_ROOT/ios/DerivedData" \
    -only-testing:"$1" \
    CODE_SIGNING_ALLOWED=NO || rc=$?
  # Clean up on the way OUT, not just on the way in (see _ios_settle_app). Every
  # xcodebuild leaves the app and its Live Activity extension alive on the device,
  # so a run that only settles BEFORE launching buries a mine for the next run:
  # measured 2026-08-09 — a bare xcodebuild leaves 2 PervioWidgets, the next run
  # hangs before a single test, and that run leaves 2 more. The "Pervio quit
  # unexpectedly" panel is the user-visible half of the same strays.
  _ios_kill_strays "$2"
  return "$rc"
}

# --------------------------------------------------- the sandbox endpoint ----
#
# ios/Tests/Transport/ is the only place in this repo that talks to a REAL SSH
# server, because host identity cannot be faked: what has to hold is that
# swift-nio-ssh refuses a server whose key is not in the pin, and only a real
# handshake can show that. Those tests find the endpoint through the environment
# and SKIP when it is absent — so for as long as this layer ran a bare
# `xcodebuild test`, the entire security boundary of the product was skipped on
# every machine, under a green "Test Suite 'HostIdentityTests' passed".
#
# So the layer now brings the endpoint up itself and ROTATES its host key, which
# is what turns one of those tests from a permanent skip into a real assertion:
# with a rotated endpoint, PERVIO_E2E_STALE_PIN is the key the server presented
# BEFORE the rotation, and pinning it must be refused. Two guards keep this from
# rotting back into a skip or into self-certification — see _ios_unit_test.
E2E_SETUP="$PERVIO_ROOT/server/tests/e2e_ios/setup.sh"
# Its own sandbox root and port: layer 3's smoke test owns the defaults
# (/tmp/pervio-e2e-ios, 2222), and two layers fighting over one port would look
# like a security failure instead of a scheduling one. The root stays under /tmp
# rather than $TMPDIR because the test process runs INSIDE the simulator and
# reads this path as an absolute host path.
UNIT_E2E_ROOT="${PERVIO_UNIT_E2E_ROOT:-/tmp/pervio-e2e-ios-unit}"
UNIT_E2E_PORT="${PERVIO_UNIT_E2E_PORT:-2223}"

_e2e() { env PERVIO_E2E_ROOT="$UNIT_E2E_ROOT" PERVIO_E2E_PORT="$UNIT_E2E_PORT" \
             bash "$E2E_SETUP" "$@"; }

# Between two xcodebuild runs the previous test host can still be holding the
# device, and the next launch then dies with "The test runner hung before
# establishing connection" / "Early unexpected exit … before establishing
# connection" — a red with nothing to do with host keys.
#
# app.pervio.widgets is not an afterthought in that list, it is the actual
# culprit: the app EMBEDS the Live Activity extension, and PervioWidgets
# processes outlive the app that started them. Measured here 2026-08-09 — two
# stray PervioWidgets from an earlier run, and every xcodebuild after them hung
# before a single test executed; terminating the extension made the very next run
# launch and pass.
_ios_kill_strays() {  # $1 = -destination — terminate app + extension, no waiting
  local udid
  udid="$(printf '%s' "$1" | sed -n 's/.*id=\([0-9A-Fa-f-]\{36\}\).*/\1/p')"
  [ -n "$udid" ] || return 0
  xcrun simctl terminate "$udid" app.pervio >/dev/null 2>&1
  xcrun simctl terminate "$udid" app.pervio.widgets >/dev/null 2>&1
}

# Before a launch, the same kill plus a moment for the device to actually let go.
# The wait belongs here and not in _xcodebuild_test's exit path: what races is the
# NEXT launch, and cleaning up after ourselves has nothing to wait for.
_ios_settle_app() {  # $1 = -destination
  _ios_kill_strays "$1"
  sleep 3
}

# THE NEGATIVE CONTROL, wired into the run instead of left to whoever remembers.
#
# testPinFromBeforeAHostKeyRotationIsRefused is only worth anything if the pin it
# is handed really is a PRE-rotation key. Hand it the key the server presents
# right now — i.e. rotate nothing — and it must go RED, saying so. If it comes
# back green, the test is certifying itself: it would pass on any machine, for
# any pin, forever. That is a harness failure and it fails this layer.
#
# "Red" is not enough on its own either: a launch that never reached the test is
# also non-zero. So the verdict is read out of the log — the test must have
# EXECUTED, and its output must carry the assertion that names the problem.
_ios_rotation_negative_control() {  # $1 = -destination, $2 = config path
  local dest="$1" cfg="$2" log="$LOG_DIR/ios-unit-negative-control.log" rc now attempt
  now="$(_e2e host-pin)" || { echo "negative control: no endpoint to ask for a host key"; return 1; }

  echo ""
  echo "-- negative control: feeding the CURRENT host key as the 'pre-rotation' pin."
  echo "   The test must FAIL. A green here means it proves nothing."
  for attempt in 1 2; do
    _ios_settle_app "$dest"
    TEST_RUNNER_PERVIO_E2E_CONFIG="$cfg" \
    TEST_RUNNER_PERVIO_E2E_STALE_PIN="$now" \
    _xcodebuild_test \
      "PervioTests/HostIdentityTests/testPinFromBeforeAHostKeyRotationIsRefused" "$dest" \
      > "$log" 2>&1
    rc=$?
    grep -q "^Test Case" "$log" && break
    # Nothing ran: a simulator/launch flake, not a verdict. Retried once, then
    # reported as broken — never quietly accepted as "well, it was red".
    echo "   attempt $attempt did not execute the test: $(grep -m1 'encountered an error' "$log")"
    if [ "$attempt" = 2 ]; then
      echo "NEGATIVE CONTROL BROKEN: the test could not be launched twice in a row, so"
      echo "nothing here proves the rotation test can fail. Log: $log"
      return 1
    fi
  done

  if grep -qE "' skipped|was skipped" "$log"; then
    echo "NEGATIVE CONTROL BROKEN: the test SKIPPED instead of failing — PERVIO_E2E_STALE_PIN"
    echo "did not reach the test process, so neither run above means anything. Log: $log"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    echo "NEGATIVE CONTROL FAILED: the rotation test PASSED while nothing had been rotated."
    echo "It is certifying itself — it would pass with any pin. Log: $log"
    return 1
  fi
  if ! grep -q "nothing was rotated" "$log"; then
    echo "NEGATIVE CONTROL FAILED: the test went red, but not for the reason it must —"
    echo "no 'nothing was rotated' assertion in the output, so it failed by accident."
    echo "Log: $log"; grep -E "error:|XCTAssert" "$log" | head -5
    return 1
  fi
  echo "-- negative control OK: red, and red for the right reason ('nothing was rotated')."
  return 0
}

# The unit layer's body: endpoint up + rotated when this machine can host one,
# then the whole PervioTests suite, then the negative control.
_ios_unit_test() {  # $1 = -destination
  local dest="$1" log="$LOG_DIR/ios-unit-xcodebuild.log" rc cfg stale ready t
  local endpoint=0
  # The reason travels to layer_ios_unit through a FILE, not a variable: this
  # function runs inside a `| tee` pipeline, i.e. a subshell, so an exported
  # variable would be thrown away with it and the summary row would say nothing.
  local why="" whyfile="$LOG_DIR/ios-unit-unverified.txt"
  rm -f "$whyfile"

  if [ ! -f "$E2E_SETUP" ]; then
    echo "ios-unit: no server/tests/e2e_ios/setup.sh — the transport tests will SKIP."
    why="no server/tests/e2e_ios/setup.sh on this machine"
  elif ! ready="$(_e2e check 2>&1)"; then
    echo "ios-unit: no sandbox SSH endpoint on this machine — the transport tests will SKIP:"
    printf '%s\n' "$ready" | sed 's/^/    /'
    # setup.sh check prints one "  MISSING <thing>" line per absent prerequisite
    # plus a "(N missing)" tally; the shopping list is what a human needs, so keep
    # the lines and drop the tally.
    why="$(printf '%s\n' "$ready" | sed -n 's/^[[:space:]]*MISSING[[:space:]]*//p' \
           | head -3 | paste -sd';' - | sed 's/;/; /g')"
    [ -n "$why" ] || why="setup.sh check says the environment is not ready"
  else
    # A sandbox that CAN start but does not is our code breaking, not a missing
    # prerequisite — the same call that run_smoke.sh makes fatal for the same
    # reason. Reporting it as "not runnable here" is how a broken harness reads
    # as green for months.
    if ! _e2e rotate; then
      echo "ios-unit: the sandbox endpoint would not come up and rotate (see above)."
      _e2e stop >/dev/null 2>&1
      return 1
    fi
    endpoint=1
    cfg="$UNIT_E2E_ROOT/config.json"
    stale="$(_e2e stale-pin)" || { echo "ios-unit: rotate reported success but left no stale pin"; _e2e stop >/dev/null 2>&1; return 1; }
  fi

  # TEST_RUNNER_<VAR> is xcodebuild's supported channel into the process that
  # hosts the tests; the prefix is stripped on the way in, so the suite reads
  # PERVIO_E2E_CONFIG / PERVIO_E2E_STALE_PIN. Setting PERVIO_E2E_CONFIG (rather
  # than letting the tests probe default paths) is deliberate: an explicitly
  # demanded endpoint that is not there is a FAILURE in SandboxEndpoint, never a
  # skip.
  if [ "$endpoint" = 1 ]; then
    export TEST_RUNNER_PERVIO_E2E_CONFIG="$cfg" TEST_RUNNER_PERVIO_E2E_STALE_PIN="$stale"
  fi
  _ios_settle_app "$dest"
  _xcodebuild_test PervioTests "$dest" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}

  # A run that executed no test at all is not a verdict about the suite, and
  # every check below reads this log as though the tests had run. With an
  # endpoint up, a hung launch comes out as "testServerKeyOutsideThePinIsRefused
  # never reported PASSED — a suite that no longer contains it looks exactly like
  # this", which sends whoever reads it hunting for a deleted test while the real
  # cause is a device an earlier run never let go of.
  #
  # Deliberately NOT retried, unlike the negative control. That one re-runs a
  # single test in seconds; this is the whole suite, so a retry doubles the wall
  # clock of every genuinely broken run, launches the app a second time (a second
  # "Pervio quit unexpectedly" on someone's screen) and would paper over exactly
  # the wedged device this message names. The cause is now cleared at the root by
  # _xcodebuild_test, so a hang that survives that is worth reporting, not hiding.
  if [ "$rc" -ne 0 ] && ! grep -q "^Test Case" "$log"; then
    echo ""
    echo "ios-unit FAILED TO LAUNCH: xcodebuild exited $rc without executing a single test."
    grep -m1 -E "encountered an error|Testing failed" "$log" | sed 's/^[[:space:]]*/    /'
    echo "Nothing in this run says anything about what the suite contains. If the runner"
    echo "hung before connecting, a process from an earlier run still owns the device:"
    echo "    xcrun simctl terminate <udid> app.pervio.widgets"
    [ "$endpoint" = 1 ] && _e2e stop >/dev/null 2>&1
    return 1
  fi

  if [ "$endpoint" = 1 ]; then
    # With a live, rotated endpoint there is nothing left in ios/Tests/ that is
    # allowed to skip: the only two XCTSkip sites in the suite are "no endpoint"
    # and "no stale pin", and this run supplied both. A skip here therefore means
    # the environment never arrived — the exact failure that hid the rotation
    # test for its whole life — so it is red, not "0 failed".
    if grep -qE "' skipped|was skipped" "$log"; then
      echo ""
      echo "ios-unit FAILED: a test SKIPPED although the endpoint was up and ROTATED."
      echo "The runner passed PERVIO_E2E_CONFIG=$cfg and a pre-rotation pin; a skip means"
      echo "they never reached the test process. A skip is not a pass."
      grep -B1 -A3 -E "' skipped|was skipped" "$log" | head -30
      rc=1
    fi
    # THE POSITIVE CONTROL. Everything above is negative: rc=0 and no "skipped"
    # only say nothing went wrong, never that the boundary was TESTED. Drop
    # ios/Tests/Transport from the test target and this branch sees a clean, fast,
    # skip-free green. So name the two tests that must be in the log as PASSED.
    for t in testServerKeyOutsideThePinIsRefused testPinFromBeforeAHostKeyRotationIsRefused; do
      grep -q "$t\]' passed" "$log" && continue
      echo ""
      echo "ios-unit FAILED: the endpoint was up and nothing skipped, but $t never"
      echo "reported PASSED. A suite that no longer contains it looks exactly like this."
      rc=1
    done
    if [ "$rc" -eq 0 ] && ! _ios_rotation_negative_control "$dest" "$cfg"; then
      rc=1
    fi
    _e2e stop >/dev/null 2>&1
    return "$rc"               # the endpoint ran: nothing is unverified
  fi

  # ---- no endpoint on this machine -----------------------------------------
  #
  # This is the branch the bug lived in. Everything above has already happened:
  # the 17 transport tests threw XCTSkip, xcodebuild counted them as "0 failures"
  # and printed "** TEST SUCCEEDED **", and until now this function returned that
  # 0 and the layer was recorded PASS. The whole security boundary of the product
  # — testServerKeyOutsideThePinIsRefused, the man-in-the-middle refusal — had
  # never run on any machine, and nothing anywhere said so.
  #
  # The verdict below is read out of the LOG, not out of what the runner intended:
  # if some other endpoint (layer 3's sandbox, an operator's own PERVIO_E2E_CONFIG)
  # happened to be up and nothing skipped, this run really did verify the boundary
  # and stays a clean PASS.
  if ! grep -qE "' skipped|was skipped" "$log"; then
    [ "$rc" -eq 0 ] || return "$rc"   # a real failure outranks everything below
    # THE OTHER HALF OF THE POSITIVE CONTROL, and the square this file was still
    # blind on. Nothing skipped — but this machine brought no endpoint up either,
    # and two very different runs are indistinguishable from here: someone else's
    # endpoint was live and the transport tests really ran, or ios/Tests/Transport
    # is not in the test target at all, in which case there is nothing to skip,
    # nothing to run, and the layer prints a fast, clean, meaningless PASS. That
    # is the shape the original bug hid in, so read the log instead of assuming
    # the good case.
    for t in testServerKeyOutsideThePinIsRefused testPinFromBeforeAHostKeyRotationIsRefused; do
      grep -q "$t\]' passed" "$log" && continue
      echo ""
      echo "ios-unit FAILED: nothing skipped, nothing failed — and $t never reported"
      echo "PASSED either, so it did not run. A test target that no longer contains the"
      echo "host-identity tests looks exactly like this: green, fast, and proving nothing."
      rc=1
    done
    return "$rc"
  fi

  printf '%s\n' "$why" > "$whyfile"
  echo ""
  echo "======================================================================"
  echo "SECURITY BOUNDARY NOT VERIFIED — $why"
  echo ""
  echo "xcodebuild printed its own SUCCEEDED above. Ignore it: these tests never"
  echo "ran, and they are the ones that hold host identity, the connect-failure"
  echo "classifications and byte-for-byte upload:"
  grep -oE "\-\[PervioTests\.[A-Za-z]+ [A-Za-z]+\]' skipped" "$log" \
    | sed -e 's/^-\[PervioTests\./    /' -e "s/\]' skipped$//" | head -20
  echo ""
  echo "Start the endpoint and this layer verifies them for you:"
  echo "    bash $E2E_SETUP check     # what is missing on this machine"
  echo "======================================================================"

  # A REAL FAILURE OUTRANKS THE DOWNGRADE. Everything above this point is about
  # tests that did not run; `rc` is about tests that ran and FAILED, and the two
  # are independent. Without this line a run that skipped the transport tests AND
  # failed seventeen others came back UNVERIFIED with exit 0 under the escape
  # hatch below — the failures swallowed whole, and the reason column claiming
  # nothing ran. "Never a pass" was honoured to the letter and broken in spirit:
  # a green exit code is what the hook and the nightly job actually read.
  if [ "$rc" -ne 0 ]; then
    echo "…and this run ALSO had real failures (xcodebuild exit $rc). That outranks"
    echo "the unverified-transport downgrade: the layer is FAIL, not UNVERIFIED."
    return "$rc"
  fi

  if [ "${PERVIO_ALLOW_UNVERIFIED_TRANSPORT:-0}" = 1 ]; then
    echo "PERVIO_ALLOW_UNVERIFIED_TRANSPORT=1 — recorded as UNVERIFIED, never as a pass."
    return 3
  fi
  echo "Set PERVIO_ALLOW_UNVERIFIED_TRANSPORT=1 to accept this knowingly; the run"
  echo "then ends in RESULT: UNVERIFIED instead of RESULT: PASS."
  return 1
}

# ------------------------------------------------------------------ layers ---

# layer 1 — the Swift unit tests (PervioTests) on a simulator. It does its own
# bookkeeping rather than calling run_layer, because _ios_unit_test has a third
# outcome run_layer cannot express: exit 3 = "ran, green, proved nothing" (see
# unverified_layer). Mapping 3 onto FAIL would be wrong and mapping it onto the
# generic non-zero path would lose the reason.
layer_ios_unit() {
  local dest log="$LOG_DIR/ios-unit.log" t0=$SECONDS rc
  if ! ensure_project; then fail_layer ios-unit "could not generate ios/Pervio.xcodeproj"; return 1; fi
  if ! dest="$(destination)"; then fail_layer ios-unit "no usable simulator -destination (see above)"; return 1; fi
  printf '\n########  %s  ########\n' ios-unit
  _ios_unit_test "$dest" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  case "$rc" in
    0) _pass=$((_pass+1)); _record ios-unit PASS "$((SECONDS-t0))";;
    3) unverified_layer ios-unit "$((SECONDS-t0))" \
         "host-identity tests never ran — $(cat "$LOG_DIR/ios-unit-unverified.txt" 2>/dev/null || echo 'no sandbox SSH endpoint')";;
    *) _fail=$((_fail+1)); _record ios-unit FAIL "$((SECONDS-t0))" "exit $rc — $log";;
  esac
  return 0
}

# layer 0 — the tests for this automation itself. It builds sandboxes that run
# copies of these very scripts, so it must not run inside one of its own
# sandboxes: PERVIO_SELFTEST_ACTIVE is set on the way in and skips the nested
# layer. Without that guard, one `test-all.sh` forks forever.
layer_scripts_selftest() {
  if [ "${PERVIO_SELFTEST_ACTIVE:-0}" = 1 ]; then
    skip_layer scripts-selftest "already inside a selftest sandbox"; return 0
  fi
  run_layer scripts-selftest env PERVIO_SELFTEST_ACTIVE=1 bash "$PERVIO_ROOT/scripts/tests/test_scripts.sh"
}

layer_server_suites() {  # layer 2 — the no-cost suites + the iOS fixture freshness check
  run_layer server-suites bash "$PERVIO_ROOT/server/tests/run_all.sh"
}

layer_server_quota_e2e() {  # opt-in only — real agents, spends model quota
  run_layer server-e2e-quota bash "$PERVIO_ROOT/server/tests/run_all.sh" --e2e
}

# layer 3 — the XCUITest smoke against a real sshd. Track C's run_smoke.sh owns
# the whole thing (sandbox sshd up, throwaway project with the UI-test target,
# xcodebuild, teardown); this layer only translates its documented exit codes:
#
#     0  ran and passed          → PASS
#     2  environment not ready   → SKIP, with the runner's own last line as the reason
#     anything else              → FAIL
#
# Exit 2 is the ONLY skip code on purpose. Treating every non-zero exit as "not
# runnable here" is how a broken smoke test hides for months.
layer_ios_ui_smoke() {
  local runner="$PERVIO_ROOT/server/tests/e2e_ios/run_smoke.sh"
  local log="$LOG_DIR/ios-ui-smoke.log" t0=$SECONDS rc
  if [ ! -f "$runner" ]; then
    skip_layer ios-ui-smoke "no server/tests/e2e_ios/run_smoke.sh (track C not present)"; return 0
  fi
  printf '\n########  ios-ui-smoke  ########\n'
  bash "$runner" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  case "$rc" in
    0) _pass=$((_pass+1)); _record ios-ui-smoke PASS "$((SECONDS-t0))";;
    2) _skip=$((_skip+1))
       _record ios-ui-smoke SKIP "$((SECONDS-t0))" "environment not ready: $(tail -1 "$log")"
       printf -- '-- SKIPPED: environment not ready — %s\n' "$(tail -1 "$log")";;
    *) _fail=$((_fail+1)); _record ios-ui-smoke FAIL "$((SECONDS-t0))" "exit $rc — $log";;
  esac
  return 0
}
