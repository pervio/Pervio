#!/usr/bin/env bash
# Tests for the test automation itself (track D artifacts):
#
#     bash scripts/tests/test_scripts.sh
#
# Everything runs in a throwaway sandbox: a fake repo tree under $TMPDIR with
# STUB xcodebuild / xcrun / xcodegen / run_all.sh on PATH and a hermetic $HOME.
# The real ~/.pervio, the real ~/Library/LaunchAgents and the real .git/hooks are
# never written — two tests assert exactly that (the hook and the launchd job are
# templates, not installs).
#
# The stubs are what give these tests teeth: they let us drive "xcodebuild
# failed", "no simulator exists", "the e2e setup says the box isn't ready"
# without needing any of those conditions to be true on this machine, and they
# record their argv so we can assert on HOW the scripts called them (e.g. that
# the destination came from simctl at runtime, that --e2e is never passed by
# accident and thus never spends model quota).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0; failed_names=()
SB=""

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); failed_names+=("$1"); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------- sandbox ----
new_sandbox() {  # $1.. = flags: --with-e2e
  # bash keeps `VAR=x somefunc` assignments alive after the call, so scrub the
  # previous test's stub knobs before building the next sandbox.
  unset STUB_XCODEBUILD_EXIT STUB_XCODEBUILD_UI_EXIT STUB_SERVER_EXIT \
        STUB_SMOKE_EXIT PERVIO_SKIP_SMOKE STUB_NO_SIMS STUB_XCODEGEN_EXIT STUB_SELFTEST_EXIT \
        PERVIO_TEST_REPORT_DIR PERVIO_SELFTEST_ACTIVE PERVIO_SKIP_IOS PERVIO_SKIP_SERVER \
        STUB_XCODEBUILD_SKIPS PERVIO_ALLOW_UNVERIFIED_TRANSPORT \
        STUB_E2E_CHECK_EXIT STUB_E2E_ROTATE_EXIT STUB_NEGCTL PERVIO_UNIT_E2E_ROOT \
        STUB_XCODEBUILD_NOLAUNCH STUB_NO_TRANSPORT_TESTS
  SB="$(mktemp -d "${TMPDIR:-/tmp}/pervio-scripts-test.XXXXXX")"
  mkdir -p "$SB/repo/server/tests" "$SB/bin" "$SB/home" "$SB/calls" "$SB/repo/ios"

  # the artifacts under test, copied verbatim out of the real repo
  [ -d "$REPO/scripts" ]   && cp -R "$REPO/scripts"   "$SB/repo/scripts"
  [ -d "$REPO/.githooks" ] && cp -R "$REPO/.githooks" "$SB/repo/.githooks"
  mkdir -p "$SB/repo/docs"
  [ -f "$REPO/docs/testing.md" ] && cp "$REPO/docs/testing.md" "$SB/repo/docs/testing.md"
  [ -f "$REPO/ios/project.yml" ] && cp "$REPO/ios/project.yml" "$SB/repo/ios/project.yml"

  # ---- stub: THIS file, inside the sandbox --------------------------------
  # test-all.sh runs the script selftest as a layer, and that selftest builds
  # sandboxes of its own. Left real, one run would fork forever. The sandbox copy
  # is therefore a stub: instant, and it records that the layer reached it.
  cat > "$SB/repo/scripts/tests/test_scripts.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/selftest.log"
echo "STUB selftest (exit ${STUB_SELFTEST_EXIT:-0})"
exit "${STUB_SELFTEST_EXIT:-0}"
STUB
  chmod +x "$SB/repo/scripts/tests/test_scripts.sh"

  # ---- stub: server suite -------------------------------------------------
  cat > "$SB/repo/server/tests/run_all.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/run_all.log"
echo "STUB run_all.sh args=[$*]"
[ "${STUB_SERVER_EXIT:-0}" != 0 ] && echo "STUB-SERVER-FAILED-MARKER"
exit "${STUB_SERVER_EXIT:-0}"
STUB
  chmod +x "$SB/repo/server/tests/run_all.sh"

  # ---- stub: the track-C smoke runner (present only when asked) -----------
  # Track C owns server/tests/e2e_ios/run_smoke.sh and documents its exit codes:
  #   0 = the smoke test ran and passed
  #   1 = it ran and failed
  #   2 = environment not ready (no simulator / no sshd) — nothing ran
  # Anything else is a runner that broke in a way it did not anticipate.
  if [ "${1:-}" = "--with-e2e" ]; then
    mkdir -p "$SB/repo/server/tests/e2e_ios"
    cat > "$SB/repo/server/tests/e2e_ios/run_smoke.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/run_smoke.log"
case "${STUB_SMOKE_EXIT:-0}" in
  0) echo "smoke: bubble carried the nonce back"; exit 0;;
  1) echo "SMOKE-FAILED-MARKER: no reply bubble within 60s"; exit 1;;
  2) echo "no sshd on 127.0.0.1:2222 — environment not ready"; exit 2;;
  *) echo "runner blew up"; exit "${STUB_SMOKE_EXIT}";;
esac
STUB
    chmod +x "$SB/repo/server/tests/e2e_ios/run_smoke.sh"
  fi

  # ---- stub: the sandbox endpoint (present only when asked) ---------------
  # The other half of e2e_ios: the throwaway sshd that layer 1 now brings up and
  # ROTATES so ios/Tests/Transport/ has a real server to talk to. Only the
  # contract layers.sh depends on is stubbed, and each subcommand is recorded, so
  # a test can assert the runner really asked for a rotation and really carried
  # the pre-rotation key into the test process.
  case " $* " in *" --with-endpoint "*)
    mkdir -p "$SB/repo/server/tests/e2e_ios"
    cat > "$SB/repo/server/tests/e2e_ios/setup.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$CALLS/e2e_setup.log"
ROOT="${PERVIO_E2E_ROOT:?the caller must point the stub endpoint at a sandbox path}"
case "${1:-}" in
  check)     exit "${STUB_E2E_CHECK_EXIT:-0}";;
  rotate)    [ "${STUB_E2E_ROTATE_EXIT:-0}" = 0 ] || exit "${STUB_E2E_ROTATE_EXIT}"
             mkdir -p "$ROOT"; printf '{}\n' > "$ROOT/config.json"
             echo "stub e2e: host key ROTATED on 127.0.0.1"; exit 0;;
  stale-pin) echo "ssh-ed25519 STUB-KEY-FROM-BEFORE-THE-ROTATION"; exit 0;;
  host-pin)  echo "ssh-ed25519 STUB-KEY-THE-SERVER-PRESENTS-NOW"; exit 0;;
  stop)      exit 0;;
  *)         exit 64;;
esac
STUB
    chmod +x "$SB/repo/server/tests/e2e_ios/setup.sh"
  ;; esac

  # ---- stub: xcodebuild ---------------------------------------------------
  cat > "$SB/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/xcodebuild.log"
# One shared, ORDERED transcript of both stubs. Which of them ran is already in
# their own logs; what the device cleanup is about is what ran AFTER what.
printf 'xcodebuild %s\n' "$*" >> "$CALLS/order.log"
# What reached the test process matters as much as what was asked for: the whole
# point of the rotation wiring is that PERVIO_E2E_STALE_PIN arrives, and the only
# supported channel is a TEST_RUNNER_ prefix.
printf 'CONFIG=%s STALE=%s\n' "${TEST_RUNNER_PERVIO_E2E_CONFIG:-}" \
       "${TEST_RUNNER_PERVIO_E2E_STALE_PIN:-}" >> "$CALLS/xcodebuild.env"
echo "STUB xcodebuild args=[$*]"
# A device an earlier run never let go of: xcodebuild exits non-zero having
# executed nothing at all. The two lines are the shape of the real failure — no
# "Test Case" line anywhere, which is the only thing that tells this apart from
# a suite whose tests were deleted.
if [ "${STUB_XCODEBUILD_NOLAUNCH:-0}" = 1 ]; then
  echo "Testing failed:"
  echo "	Pervio (41234) encountered an error (The test runner hung before establishing connection.)"
  echo "** TEST FAILED **"
  exit 65
fi
negctl=0
for a in "$@"; do
  case "$a" in
    *PervioUITests*) code="${STUB_XCODEBUILD_UI_EXIT:-0}";;
    *testPinFromBeforeAHostKeyRotationIsRefused*) negctl=1;;
  esac
done
# The negative-control invocation: the runner re-runs ONE test with the CURRENT
# host key as the "pre-rotation" pin, and it must come back red for the stated
# reason. STUB_NEGCTL replays each way that can go wrong.
if [ "$negctl" = 1 ]; then
  T="Test Case '-[PervioTests.HostIdentityTests testPinFromBeforeAHostKeyRotationIsRefused]'"
  # nolaunch prints no "Test Case" line at all, because that is what a simulator
  # that never started the runner looks like — non-zero, but not a verdict.
  [ "${STUB_NEGCTL:-red}" = nolaunch ] || echo "$T started."
  case "${STUB_NEGCTL:-red}" in
    green)    echo "$T passed (0.03 seconds)."; echo "** TEST SUCCEEDED **"; exit 0;;
    skip)     echo "$T skipped (0.00 seconds)."; echo "** TEST SUCCEEDED **"; exit 0;;
    wrong)    echo "HostIdentityTests.swift:289: error: $T : failed - the box was on fire"
              echo "$T failed (0.03 seconds)."; echo "** TEST FAILED **"; exit 65;;
    nolaunch) echo "Testing failed:"
              echo "	Pervio (999) encountered an error (The test runner hung before establishing connection.)"
              echo "** TEST FAILED **"; exit 65;;
    *)        echo "HostIdentityTests.swift:281: error: $T : XCTAssertNotEqual failed - PERVIO_E2E_STALE_PIN is the key the server presents NOW — nothing was rotated, so this test would prove nothing"
              echo "$T failed (0.03 seconds)."; echo "** TEST FAILED **"; exit 65;;
  esac
fi
code="${code:-${STUB_XCODEBUILD_EXIT:-0}}"
# A target that still CONTAINS ios/Tests/Transport prints one "passed" line per
# transport test — with this run's endpoint or with somebody else's, which is why
# it does not depend on TEST_RUNNER_PERVIO_E2E_CONFIG. Those lines are the only
# evidence either positive control can read. STUB_NO_TRANSPORT_TESTS=1 drops them
# and models a target those tests were removed from: green, skip-free, silent.
if [ "${STUB_NO_TRANSPORT_TESTS:-0}" != 1 ] && [ "${STUB_XCODEBUILD_SKIPS:-0}" != 1 ]; then
  for t in testServerKeyOutsideThePinIsRefused testPinFromBeforeAHostKeyRotationIsRefused; do
    echo "Test Case '-[PervioTests.HostIdentityTests $t]' passed (0.42 seconds)."
  done
fi
# STUB_XCODEBUILD_SKIPS=1 reproduces the exact shape of the bug this harness has
# to catch: XCTSkip'd tests, "0 failures", exit 0, and a clean SUCCEEDED printed
# on top. The five lines below are VERBATIM from a real unfixed run of this repo
# (2026-08-09, $TMPDIR/pervio-test-logs/ios-unit.log) — copied rather than
# paraphrased because the guard that reads them is a grep, and a paraphrase would
# let the grep rot without any test noticing.
if [ "${STUB_XCODEBUILD_SKIPS:-0}" = 1 ]; then
  cat <<'SKIPS'
Test Case '-[PervioTests.HostIdentityTests testServerKeyOutsideThePinIsRefused]' skipped (0.001 seconds).
Test Case '-[PervioTests.HostIdentityTests testCorrectKeyAndPinnedHostKeyConnectAndRunACommand]' skipped (0.002 seconds).
Test Case '-[PervioTests.ConnectFailureTests testClosedPortIsItsOwnError]' skipped (0.008 seconds).
Test Case '-[PervioTests.UploadTransferTests testSmallFileArrivesByteForByte]' skipped (0.002 seconds).
	 Executed 188 tests, with 17 tests skipped and 0 failures (0 unexpected) in 0.977 (1.036) seconds
SKIPS
fi
if [ "$code" != 0 ]; then
  echo "** TEST FAILED **"
  echo "STUB-XCODEBUILD-FAILED-MARKER"
else
  echo "** TEST SUCCEEDED **"
fi
exit "$code"
STUB
  chmod +x "$SB/bin/xcodebuild"

  # ---- stub: xcrun (simctl device list) -----------------------------------
  cat > "$SB/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/xcrun.log"
printf 'xcrun %s\n' "$*" >> "$CALLS/order.log"
if [ "${1:-}" = "simctl" ]; then
  if [ "${STUB_NO_SIMS:-0}" = 1 ]; then
    case " $* " in
      *--json*) echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[]}}';;
      *)        printf '== Devices ==\n-- iOS 26.5 --\n';;
    esac
    exit 0
  fi
  case " $* " in
    *--json*)
      cat <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
 {"name":"iPad mini (A17 Pro)","udid":"DEAD0000-0000-4000-8000-00000000BEEF","state":"Shutdown","isAvailable":true},
 {"name":"Stub iPhone 42","udid":"5747B0DE-0000-4000-8000-00000000CAFE","state":"Shutdown","isAvailable":true}
]}}
JSON
      ;;
    *)
      printf '== Devices ==\n-- iOS 26.5 --\n    iPad mini (A17 Pro) (DEAD0000-0000-4000-8000-00000000BEEF) (Shutdown)\n    Stub iPhone 42 (5747B0DE-0000-4000-8000-00000000CAFE) (Shutdown)\n';;
  esac
  exit 0
fi
exit 0
STUB
  chmod +x "$SB/bin/xcrun"

  # ---- stub: xcodegen -----------------------------------------------------
  cat > "$SB/bin/xcodegen" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/xcodegen.log"
mkdir -p "$SB_TMP/repo/ios/Pervio.xcodeproj"
echo "STUB xcodegen args=[$*]"
exit "${STUB_XCODEGEN_EXIT:-0}"
STUB
  chmod +x "$SB/bin/xcodegen"
}

drop_sandbox() { [ -n "$SB" ] && rm -rf "$SB"; SB=""; }

# Run a command inside the sandbox with stubs on PATH and a hermetic HOME.
# stdout+stderr → $SB/out.txt ; exit code → $SB/code.txt
sb_run() {
  ( cd "$SB/repo" && env \
      PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$SB/home" \
      CALLS="$SB/calls" \
      SB_TMP="$SB" \
      "$@" ) > "$SB/out.txt" 2>&1
  echo $? > "$SB/code.txt"
}
sb_out()  { cat "$SB/out.txt"; }
sb_code() { cat "$SB/code.txt"; }
calls()   { cat "$SB/calls/$1" 2>/dev/null || true; }
# A stub invoked with NO arguments logs an empty line, so "$(calls x)" is blank
# even though it ran — ask the filesystem, not the contents.
ran()     { [ -f "$SB/calls/$1" ]; }

# The one date-shaped report under $1, if any. Globbing instead of recomputing
# `date` keeps these tests from flaking when a run straddles midnight, while
# still pinning the <YYYY-MM-DD>.log naming contract.
report_log() {
  local f
  f="$(ls -1 "$1" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$' | head -1)"
  [ -n "$f" ] && printf '%s/%s\n' "$1" "$f"
}

# ------------------------------------------------------------------ tests ----

t_fast_ios_failure_propagates() {  # D-T1
  local n="D-T1 test-fast.sh: a failing xcodebuild test makes the script exit non-zero"
  new_sandbox
  STUB_XCODEBUILD_EXIT=65 sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit was 0 despite xcodebuild exiting 65 (a tee/pipe would swallow it). out: $(sb_out | tail -3 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'STUB-XCODEBUILD-FAILED-MARKER'; then
    bad "$n" "the failing layer's own output was swallowed — nothing to debug from; out: $(sb_out | tail -5 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'SUMMARY: 1 passed, 1 failed, 0 skipped'; then
    bad "$n" "summary does not say 1 passed / 1 failed (both layers must still run); out: $(sb_out | tail -5 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_fast_server_failure_propagates() {  # D-T2
  local n="D-T2 test-fast.sh: a failing server suite makes the script exit non-zero"
  new_sandbox
  STUB_SERVER_EXIT=1 sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit was 0 despite run_all.sh exiting 1. out: $(sb_out | tail -3 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'STUB-SERVER-FAILED-MARKER'; then
    bad "$n" "run_all.sh's failure output was swallowed; out: $(sb_out | tail -5 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'SUMMARY: 1 passed, 1 failed, 0 skipped'; then
    bad "$n" "summary does not say 1 passed / 1 failed; out: $(sb_out | tail -5 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_fast_green_runs_both_layers() {  # D-T3
  local n="D-T3 test-fast.sh: all green → exit 0 and BOTH layers actually ran"
  new_sandbox
  sb_run bash scripts/test-fast.sh
  local c; c="$(sb_code)"
  if [ "$c" != 0 ]; then
    bad "$n" "exit=$c; out: $(sb_out | tail -5 | tr '\n' ' ')"
  elif ! calls xcodebuild.log | grep -qE '(^| )test( |$)'; then
    bad "$n" "xcodebuild was never asked to 'test' (calls: $(calls xcodebuild.log | tr '\n' '|'))"
  elif ! ran run_all.log; then
    bad "$n" "server/tests/run_all.sh was never run"
  elif ! sb_out | grep -q 'SUMMARY: 2 passed, 0 failed, 0 skipped'; then
    bad "$n" "no 'SUMMARY: 2 passed, 0 failed, 0 skipped' line; out: $(sb_out | tail -5 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_fast_destination_from_simctl() {  # D-T4
  local n="D-T4 test-fast.sh: -destination comes from simctl at runtime, not a hardcoded model"
  new_sandbox
  sb_run bash scripts/test-fast.sh
  local xb; xb="$(calls xcodebuild.log)"
  if ! printf '%s' "$xb" | grep -q '5747B0DE-0000-4000-8000-00000000CAFE'; then
    bad "$n" "destination did not carry the udid simctl reported. xcodebuild args: ${xb:-<none>}"
  elif printf '%s' "$xb" | grep -qE 'name=iPhone (1[0-9]|Air)'; then
    bad "$n" "destination hardcodes a real device model: ${xb}"
  else ok "$n"; fi
  drop_sandbox
}

t_fast_no_simulator_is_loud() {  # D-T5
  local n="D-T5 test-fast.sh: zero available simulators → non-zero exit, clear message, no xcodebuild"
  new_sandbox
  STUB_NO_SIMS=1 sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0 with no simulator — a green run that tested nothing"
  elif ! sb_out | grep -qi 'simulator'; then
    bad "$n" "no message mentioning the simulator; out: $(sb_out | tail -5 | tr '\n' ' ')"
  elif calls xcodebuild.log | grep -q ' test'; then
    bad "$n" "xcodebuild test was launched anyway (would hang waiting for a destination)"
  else ok "$n"; fi
  drop_sandbox
}

t_fast_never_spends_quota() {  # D-T6
  local n="D-T6 test-fast.sh: never passes --e2e (the quota-spending real-agent suites)"
  new_sandbox
  sb_run bash scripts/test-fast.sh
  if ! ran run_all.log; then
    bad "$n" "run_all.sh was never invoked at all — nothing was proven about --e2e"
  elif calls run_all.log | grep -q -- '--e2e'; then
    bad "$n" "run_all.sh got --e2e: $(calls run_all.log | tr '\n' '|')"
  else ok "$n"; fi
  drop_sandbox
}

# ---- the skipped security boundary --------------------------------------
#
# Measured on this repo, 2026-08-09: every runner it ships printed
#
#     Executed 188 tests, with 17 tests skipped and 0 failures (0 unexpected)
#     ** TEST SUCCEEDED **
#     RESULT: PASS
#
# and all 17 skips were ios/Tests/Transport/ — the tests that need a real sshd,
# including testServerKeyOutsideThePinIsRefused, which is the product's
# man-in-the-middle refusal. A skipped test had exactly the same colour as a
# passing one, so the security boundary had never been exercised anywhere.
#
# The sandbox these four tests run in has no server/tests/e2e_ios/setup.sh, which
# is precisely the machine the bug hid on: the layer cannot bring an endpoint up,
# so the transport tests skip. What must never happen again is that this reads as
# a pass.

t_ios_unit_skips_are_not_a_pass() {  # D-T27
  local n="D-T27 test-fast.sh: XCTSkip'd transport tests + xcodebuild exit 0 must NOT be a pass"
  new_sandbox
  STUB_XCODEBUILD_SKIPS=1 PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if ! sb_out | grep -q '\*\* TEST SUCCEEDED \*\*'; then
    bad "$n" "the stub did not reproduce the bug (no 'TEST SUCCEEDED' in the output) — the test proves nothing"
  elif [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0: a run whose security tests all skipped still reads as green. out: $(sb_out | tail -6 | tr '\n' ' ')"
  # Anchored: the verdict is a line of its own. An unanchored match also hits the
  # advice text ("… instead of RESULT: PASS"), which would make this test red for
  # a runner that behaved perfectly.
  elif sb_out | grep -q '^RESULT: PASS'; then
    bad "$n" "the summary still says RESULT: PASS; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'SECURITY BOUNDARY NOT VERIFIED'; then
    bad "$n" "nothing told the human WHY the run is red; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_names_what_went_unverified() {  # D-T28
  local n="D-T28 test-fast.sh: the unverified run names the tests that did not run"
  new_sandbox
  STUB_XCODEBUILD_SKIPS=1 PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  # Naming the man-in-the-middle test specifically: "17 tests skipped" is a number
  # nobody chases, "testServerKeyOutsideThePinIsRefused did not run" is not.
  if ! sb_out | grep -q 'testServerKeyOutsideThePinIsRefused'; then
    bad "$n" "the skipped host-identity test was never named; out: $(sb_out | tail -10 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'HostIdentityTests'; then
    bad "$n" "the skipped suite was never named; out: $(sb_out | tail -10 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'setup.sh check'; then
    bad "$n" "no command to fix it — a red with no next step; out: $(sb_out | tail -10 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_unverified_optout_is_not_pass() {  # D-T29
  local n="D-T29 PERVIO_ALLOW_UNVERIFIED_TRANSPORT=1: run continues, but RESULT is UNVERIFIED, not PASS"
  new_sandbox
  STUB_XCODEBUILD_SKIPS=1 PERVIO_ALLOW_UNVERIFIED_TRANSPORT=1 PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" != 0 ]; then
    bad "$n" "the explicit opt-out must let the run finish (exit 0), got $(sb_code); out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif sb_out | grep -q '^RESULT: PASS'; then
    bad "$n" "opting out turned the lie back on: the summary says RESULT: PASS; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q '^RESULT: UNVERIFIED'; then
    bad "$n" "no RESULT: UNVERIFIED line for a machine that could not test the boundary; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 0 failed, [0-9]+ skipped, 1 unverified'; then
    bad "$n" "the counts line does not carry the unverified layer; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE '^  ios-unit +UNVER'; then
    bad "$n" "the layer table still shows ios-unit as something other than UNVER; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_no_skips_is_still_a_clean_pass() {  # D-T30
  local n="D-T30 the skip guard is not a blanket red: a run with no skips still ends RESULT: PASS"
  new_sandbox
  PERVIO_TEST_LOG_DIR="$SB/logs" sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" != 0 ]; then
    bad "$n" "a clean run was failed by the new guard; out: $(sb_out | tail -8 | tr '\n' ' ')"
  elif ! sb_out | grep -q '^RESULT: PASS'; then
    bad "$n" "a clean run no longer says RESULT: PASS; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif sb_out | grep -q 'SECURITY BOUNDARY NOT VERIFIED'; then
    bad "$n" "the banner fired on a run where nothing skipped; out: $(sb_out | tail -8 | tr '\n' ' ')"
  elif sb_out | grep -q '^SUMMARY:.*unverified'; then
    bad "$n" "the counts line grew an unverified column with nothing unverified; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

# ------------------------------------------------ the host-key rotation (D-T31+)
#
# ios/Tests/Transport/HostIdentityTests.swift has one test that covers the case
# that actually happens to people — the box was rebuilt, or somebody else is
# answering on its address, and the pin you saved last week must now be refused:
# testPinFromBeforeAHostKeyRotationIsRefused. It can only run if something really
# rotated the sandbox's host key and handed it the key from BEFORE, through
# PERVIO_E2E_STALE_PIN. Nothing ever set that variable, so for its whole life the
# test was a guaranteed XCTSkip inside a green suite.
#
# These tests hold the wiring that fixed it, and — the part that matters — they
# hold the NEGATIVE CONTROL. Feed the same test the key the server presents right
# now and it must go red saying nothing was rotated. If that ever comes back
# green, the test proves nothing at all, and D-T32 is what says so out loud
# instead of leaving it to whoever remembers to check by hand.

t_ios_unit_rotates_and_hands_over_the_stale_pin() {  # D-T31
  local n="D-T31 layer 1: with an endpoint present it ROTATES the host key and passes the old one in"
  new_sandbox --with-endpoint
  PERVIO_UNIT_E2E_ROOT="$SB/e2e-root" PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if ! calls e2e_setup.log | grep -qx rotate; then
    bad "$n" "the runner never asked setup.sh to rotate: [$(calls e2e_setup.log | tr '\n' ' ')]"
  elif ! grep -q 'STALE=ssh-ed25519 STUB-KEY-FROM-BEFORE-THE-ROTATION' "$SB/calls/xcodebuild.env"; then
    bad "$n" "PERVIO_E2E_STALE_PIN never reached the test process — the test would still skip; env: [$(cat "$SB/calls/xcodebuild.env" 2>/dev/null | tr '\n' ' ')]"
  elif ! grep -q "CONFIG=$SB/e2e-root/config.json" "$SB/calls/xcodebuild.env"; then
    bad "$n" "the endpoint config was not demanded explicitly, so a dead endpoint would SKIP instead of FAIL; env: [$(cat "$SB/calls/xcodebuild.env" 2>/dev/null | tr '\n' ' ')]"
  elif ! calls e2e_setup.log | grep -qx stop; then
    bad "$n" "the sandbox sshd was left running after the layer"
  elif [ "$(sb_code)" != 0 ]; then
    bad "$n" "a fully wired, fully green run still failed; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_negative_control_catches_a_self_certifying_test() {  # D-T32
  local n="D-T32 layer 1: a rotation test that PASSES with nothing rotated fails the run"
  new_sandbox --with-endpoint
  STUB_NEGCTL=green PERVIO_UNIT_E2E_ROOT="$SB/e2e-root" PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0: the test passed while nothing had been rotated and the run still went green"
  elif sb_out | grep -q 'RESULT: PASS'; then
    bad "$n" "the summary still says RESULT: PASS; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'certifying itself'; then
    bad "$n" "nothing said WHY it is red (a self-certifying test); out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_negative_control_needs_the_right_red() {  # D-T33
  local n="D-T33 layer 1: the negative control is not satisfied by any old red"
  new_sandbox --with-endpoint
  # Red, but for an unrelated reason. That is not evidence the pin check works —
  # it is evidence something else broke, and it must not count as a control.
  STUB_NEGCTL=wrong PERVIO_UNIT_E2E_ROOT="$SB/e2e-root" PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "a red for the wrong reason was accepted as the negative control"
  elif ! sb_out | grep -q 'not for the reason it must'; then
    bad "$n" "the run is red but never says the control failed for the wrong reason; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_skip_with_a_live_endpoint_is_red() {  # D-T34
  local n="D-T34 layer 1: a SKIP after a real rotation is a failure, not an unverified run"
  new_sandbox --with-endpoint
  # The endpoint is up and rotated, so the two XCTSkip sites in ios/Tests/ have
  # both been supplied. A skip now can only mean the environment never arrived —
  # the exact way this whole test hid for its entire life.
  STUB_XCODEBUILD_SKIPS=1 PERVIO_UNIT_E2E_ROOT="$SB/e2e-root" PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0 although tests skipped on a machine that HAD a rotated endpoint"
  elif ! sb_out | grep -q 'SKIPPED although the endpoint was up and ROTATED'; then
    bad "$n" "the red does not name the contradiction; out: $(sb_out | tail -10 | tr '\n' ' ')"
  elif sb_out | grep -q 'RESULT: UNVERIFIED'; then
    bad "$n" "filed as UNVERIFIED, but the endpoint WAS there — this is a plain failure; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

# ---- what the layer leaves behind, and what it says when it cannot start -----
#
# Four things below this line were fixed and, until these tests, held by nothing:
# deleting any of them left all 35 assertions green.

t_ios_unit_clears_strays_after_the_run() {  # D-T35
  local n="D-T35 layer 1: the app + Live Activity extension are killed AFTER the run, not only before it"
  new_sandbox
  PERVIO_TEST_LOG_DIR="$SB/logs" sb_run bash scripts/test-fast.sh
  # The two stubs share one ordered transcript, so "before" and "after" are line
  # numbers in it rather than a guess about who ran when.
  local order="$SB/calls/order.log" first_kill first_build last_build last_kill
  first_kill="$(grep -n 'terminate .* app\.pervio\.widgets' "$order" 2>/dev/null | head -1 | cut -d: -f1)"
  last_kill="$(grep -n 'terminate .* app\.pervio\.widgets' "$order" 2>/dev/null | tail -1 | cut -d: -f1)"
  first_build="$(grep -n '^xcodebuild ' "$order" 2>/dev/null | head -1 | cut -d: -f1)"
  last_build="$(grep -n '^xcodebuild ' "$order" 2>/dev/null | tail -1 | cut -d: -f1)"
  if [ -z "$first_build" ]; then
    bad "$n" "xcodebuild never ran, so this proves nothing about the device it left behind"
  elif [ -z "$first_kill" ] || [ "$first_kill" -gt "$first_build" ]; then
    bad "$n" "nothing was terminated before the launch — a stray from an EARLIER run hangs this one; order: $(tr '\n' '|' < "$order" | cut -c1-200)"
  elif [ "$last_kill" -lt "$last_build" ]; then
    bad "$n" "the last launch was never cleaned up after: PervioWidgets from THIS run is still on the device, which is the mine the NEXT run steps on"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_hang_is_not_blamed_on_a_deleted_test() {  # D-T36
  local n="D-T36 layer 1: a runner that never launched is reported as a launch failure, not as a missing test"
  new_sandbox --with-endpoint
  # xcodebuild exits 65 having executed nothing. Everything the layer knows comes
  # out of that log, and an empty log satisfies "the test never reported PASSED"
  # just as well as a deleted test does — so it must be told apart by hand.
  STUB_XCODEBUILD_NOLAUNCH=1 PERVIO_UNIT_E2E_ROOT="$SB/e2e-root" PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0 although xcodebuild executed no test at all; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif sb_out | grep -q 'no longer contains'; then
    bad "$n" "a hung launch was blamed on a suite that 'no longer contains' the test — the reader goes looking for a deleted test that is right there; out: $(sb_out | tail -8 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'FAILED TO LAUNCH'; then
    bad "$n" "the red never says the runner did not launch; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_absent_transport_tests_are_red_without_an_endpoint() {  # D-T37
  local n="D-T37 layer 1 (no endpoint): nothing skipped AND no transport test in the log is not a pass"
  new_sandbox
  # The blind square: no endpoint, so the positive control that only lives in the
  # endpoint branch never runs — and a target without ios/Tests/Transport has
  # nothing to skip either. rc=0, no skips, clean PASS, nothing tested.
  STUB_NO_TRANSPORT_TESTS=1 PERVIO_TEST_LOG_DIR="$SB/logs" sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0: a target with the host-identity tests removed reads as a clean green; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif sb_out | grep -q '^RESULT: PASS'; then
    bad "$n" "the summary still says RESULT: PASS; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'testServerKeyOutsideThePinIsRefused'; then
    bad "$n" "the red does not name the test that never ran; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_absent_transport_tests_are_red_with_an_endpoint() {  # D-T38
  local n="D-T38 layer 1 (endpoint up): a rotated endpoint plus no transport test in the log is not a pass"
  new_sandbox --with-endpoint
  STUB_NO_TRANSPORT_TESTS=1 PERVIO_UNIT_E2E_ROOT="$SB/e2e-root" PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0: the endpoint was up and rotated for a suite that no longer runs those tests; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'testServerKeyOutsideThePinIsRefused'; then
    bad "$n" "the red does not name the test that never ran; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_ios_unit_negative_control_retries_a_launch_flake() {  # D-T39
  local n="D-T39 layer 1: a negative control that never launched is retried once, then named as a launch failure"
  new_sandbox --with-endpoint
  STUB_NEGCTL=nolaunch PERVIO_UNIT_E2E_ROOT="$SB/e2e-root" PERVIO_TEST_LOG_DIR="$SB/logs" \
    sb_run bash scripts/test-fast.sh
  # Only the negative control names one test on the command line; the main run
  # asks for the whole target, so this counts attempts, not runs.
  local tries; tries="$(calls xcodebuild.log | grep -c 'testPinFromBeforeAHostKeyRotationIsRefused')"
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0 although the negative control never executed a thing; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif [ "$tries" -lt 2 ]; then
    bad "$n" "the control was launched $tries time(s): one simulator flake now throws the layer away instead of trying again"
  elif sb_out | grep -q 'not for the reason it must'; then
    bad "$n" "a launch that executed nothing was filed as 'red for the wrong reason' — that sends you reading an assertion that never ran; out: $(sb_out | tail -8 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'could not be launched twice in a row'; then
    bad "$n" "nothing says the control could not be launched; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_runs_smoke_no_quota() {  # D-T7
# D-T7b: the REAL run_smoke.sh must reserve exit 2 for a missing external
# prerequisite. A sandbox that will not start, a pervio-chat that cannot complete
# a turn, or a spec xcodegen rejects are OUR failures — if any of them exits 2
# the layer runner files it as SKIP and a broken pipeline reads as green.
t_smoke_exit_semantics() {
  local n="D-T7b run_smoke.sh: harness/production failures exit FAIL, not SKIP"
  local sb; sb="$(mktemp -d)"
  mkdir -p "$sb/e2e"
  cp "$REPO/server/tests/e2e_ios/run_smoke.sh" "$sb/e2e/run_smoke.sh"
  # A setup.sh whose `check` passes (prerequisites are fine) but whose `start`
  # fails — precisely the "our own harness broke" case.
  cat > "$sb/e2e/setup.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  check) exit 0 ;;
  start) echo "boom: sshd would not start" >&2; exit 1 ;;
  *)     exit 0 ;;
esac
STUB
  chmod +x "$sb/e2e/setup.sh" "$sb/e2e/run_smoke.sh"
  # Stub the external prerequisites so the run reaches the sandbox start.
  mkdir -p "$sb/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/bin/xcodebuild"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/bin/xcodegen"
  cat > "$sb/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# simctl list --json: one booted iPhone, so the simulator gate passes
echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"name":"iPhone 17 Pro","udid":"TEST-UDID","state":"Booted","isAvailable":true}]}}'
STUB
  chmod +x "$sb/bin/xcodebuild" "$sb/bin/xcodegen" "$sb/bin/xcrun"
  local rc=0
  PATH="$sb/bin:$PATH" bash "$sb/e2e/run_smoke.sh" >"$sb/out.log" 2>&1 || rc=$?
  rm -rf "$sb"
  if [ "$rc" = "2" ]; then
    bad "$n" "a sandbox that would not start exited 2 (SKIP) — a broken harness must be FAIL"
  elif [ "$rc" = "0" ]; then
    bad "$n" "a sandbox that would not start exited 0 — that is worse"
  else
    ok "$n"
  fi
}

  local n="D-T7 test-all.sh: default run drives track C's run_smoke.sh and still passes no --e2e"
  new_sandbox --with-e2e
  sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if [ "$c" != 0 ]; then
    bad "$n" "exit=$c on an all-green sandbox; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! ran run_smoke.log; then
    bad "$n" "server/tests/e2e_ios/run_smoke.sh was never run"
  elif ! sb_out | grep -qE 'SUMMARY: 4 passed, 0 failed, 0 skipped'; then
    bad "$n" "expected 4 green layers (selftest, ios-unit, server-suites, ios-ui-smoke); out: $(sb_out | tail -8 | tr '\n' ' ')"
  elif calls run_all.log | grep -q -- '--e2e'; then
    bad "$n" "run_all.sh got --e2e without --with-quota: $(calls run_all.log | tr '\n' '|')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_missing_e2e_is_honest() {  # D-T8
  local n="D-T8 test-all.sh: missing e2e_ios/run_smoke.sh is reported as SKIPPED, not as a pass"
  new_sandbox                       # no --with-e2e → the track-C files do not exist
  sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if [ "$c" != 0 ]; then
    bad "$n" "exit=$c — a best-effort track that is absent must not fail the run; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 0 failed, 1 skipped'; then
    bad "$n" "the summary does not count the missing track as skipped; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'RESULT: PASS (1 skipped)'; then
    bad "$n" "verdict does not carry the skip — a bare PASS overstates what ran; out: $(sb_out | tail -3 | tr '\n' ' ')"
  elif ! sb_out | grep -qi 'ios-ui-smoke'; then
    bad "$n" "the skipped layer is not even named; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_env_not_ready_is_skip() {  # D-T9
  local n="D-T9 test-all.sh: run_smoke.sh exit 2 ('not ready') → SKIP carrying the reason"
  new_sandbox --with-e2e
  STUB_SMOKE_EXIT=2 sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if [ "$c" != 0 ]; then
    bad "$n" "exit=$c — 'environment not ready' is a skip, not a failure; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 0 failed, 1 skipped'; then
    bad "$n" "not counted as skipped; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'environment not ready'; then
    bad "$n" "the runner's reason was swallowed; out: $(sb_out | tail -8 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_smoke_failure_is_red() {  # D-T10
  local n="D-T10 test-all.sh: run_smoke.sh exit 1 (ran and failed) fails the whole run"
  new_sandbox --with-e2e
  STUB_SMOKE_EXIT=1 sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if [ "$c" = 0 ]; then
    bad "$n" "exit 0 with a failing UI smoke; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 1 failed'; then
    bad "$n" "the failure is not in the summary; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'SMOKE-FAILED-MARKER'; then
    bad "$n" "the runner's own output was swallowed; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_with_quota_flag() {  # D-T11
  local n="D-T11 test-all.sh --with-quota: only then does run_all.sh get --e2e"
  new_sandbox --with-e2e
  sb_run bash scripts/test-all.sh --with-quota
  if ! calls run_all.log | grep -q -- '--e2e'; then
    bad "$n" "--with-quota did not reach run_all.sh: $(calls run_all.log | tr '\n' '|')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_only_two_is_a_skip() {  # D-T22
  local n="D-T22 test-all.sh: exit 2 is the ONLY skip code — an unexpected exit 3 is red"
  new_sandbox --with-e2e
  STUB_SMOKE_EXIT=3 sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if [ "$c" = 0 ]; then
    bad "$n" "a runner that blew up (exit 3) was treated as 'not ready' and swept into a skip; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 1 failed, 0 skipped'; then
    bad "$n" "exit 3 did not land as a failed layer; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_runs_the_selftest() {  # D-T23
  local n="D-T23 test-all.sh: runs the script selftest as a layer; a red selftest is a red run"
  new_sandbox --with-e2e
  STUB_SELFTEST_EXIT=1 sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if ! ran selftest.log; then
    bad "$n" "scripts/tests/test_scripts.sh was never run — the automation is untested nightly"
  elif [ "$c" = 0 ]; then
    bad "$n" "exit 0 with a failing selftest; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 1 failed'; then
    bad "$n" "the selftest failure is not in the summary; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_selftest_does_not_recurse() {  # D-T24
  local n="D-T24 test-all.sh: inside a selftest sandbox the selftest layer skips (no infinite fork)"
  new_sandbox --with-e2e
  PERVIO_SELFTEST_ACTIVE=1 sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if ran selftest.log; then
    bad "$n" "the nested run launched the selftest again — that is the recursion"
  elif [ "$c" != 0 ]; then
    bad "$n" "exit=$c; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 0 failed, 1 skipped'; then
    bad "$n" "the skipped selftest is not counted; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_honors_skip_smoke() {  # D-T26
  local n="D-T26 test-all.sh honors PERVIO_SKIP_SMOKE (layer 3's sshd/simulator may be busy)"
  new_sandbox --with-e2e
  PERVIO_SKIP_SMOKE=1 sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if [ "$c" != 0 ]; then
    bad "$n" "exit=$c; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ran run_smoke.log; then
    bad "$n" "PERVIO_SKIP_SMOKE=1 but run_smoke.sh ran anyway"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 0 failed, 1 skipped'; then
    bad "$n" "the skip is not counted; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! sb_out | grep -q 'PERVIO_SKIP_SMOKE=1'; then
    bad "$n" "the skip reason does not say why; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_all_honors_skip_knobs() {  # D-T25
  local n="D-T25 test-all.sh honors PERVIO_SKIP_IOS / PERVIO_SKIP_SERVER (as docs/testing.md claims)"
  new_sandbox --with-e2e
  PERVIO_SKIP_IOS=1 PERVIO_SKIP_SERVER=1 sb_run bash scripts/test-all.sh
  local c; c="$(sb_code)"
  if [ "$c" != 0 ]; then
    bad "$n" "exit=$c; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ran xcodebuild.log; then
    bad "$n" "PERVIO_SKIP_IOS=1 but xcodebuild still ran: $(calls xcodebuild.log | tr '\n' '|')"
  elif ran run_all.log; then
    bad "$n" "PERVIO_SKIP_SERVER=1 but run_all.sh still ran"
  elif ! sb_out | grep -qE 'SUMMARY: [0-9]+ passed, 0 failed, 2 skipped'; then
    bad "$n" "both skips are not counted; out: $(sb_out | tail -6 | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

# ---- pre-push hook: driven through a REAL git push, not by calling the file --
git_sandbox_push() {  # $1 = expected outcome label; returns push exit code in $SB/code.txt
  ( cd "$SB/repo" && env \
      PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$SB/home" CALLS="$SB/calls" SB_TMP="$SB" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      STUB_XCODEBUILD_EXIT="${STUB_XCODEBUILD_EXIT:-0}" \
      STUB_SERVER_EXIT="${STUB_SERVER_EXIT:-0}" \
      git push origin main ) > "$SB/out.txt" 2>&1
  echo $? > "$SB/code.txt"
}

# --git-dir keeps this working under safe.bareRepository=explicit (this machine's
# real ~/.gitconfig sets it), and reads the bare remote without cd-ing into it.
remote_has_main() {
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git --git-dir="$SB/remote.git" rev-parse --verify -q main >/dev/null 2>&1
}

init_git_sandbox() {
  ( cd "$SB/repo" && env HOME="$SB/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash -c '
      git init -q -b main .
      git config user.email t@example.com
      git config user.name  Test
      git config core.hooksPath .githooks
      git init -q --bare ../remote.git
      git remote add origin ../remote.git
      echo hi > file.txt
      git add -A
      git commit -qm seed
  ' ) >/dev/null 2>&1
}

t_hook_blocks_failing_push() {  # D-T12
  local n="D-T12 pre-push hook: a red test-fast blocks the push (real git push)"
  new_sandbox
  init_git_sandbox
  STUB_XCODEBUILD_EXIT=65 git_sandbox_push
  local c; c="$(sb_code)"
  if [ "$c" = 0 ]; then
    bad "$n" "git push SUCCEEDED with failing tests; out: $(sb_out | tail -6 | tr '\n' ' ')"
  elif ! remote_has_main; then
    ok "$n"
  else
    bad "$n" "the remote received main even though the hook was supposed to block"
  fi
  drop_sandbox
}

t_hook_allows_green_push() {  # D-T13
  local n="D-T13 pre-push hook: a green test-fast lets the push through"
  new_sandbox
  init_git_sandbox
  git_sandbox_push
  local c; c="$(sb_code)"
  if [ "$c" != 0 ]; then
    bad "$n" "push blocked on an all-green sandbox (exit=$c); out: $(sb_out | tail -8 | tr '\n' ' ')"
  elif ! remote_has_main; then
    bad "$n" "push reported success but the remote has no main"
  elif ! ran xcodebuild.log || ! ran run_all.log; then
    bad "$n" "the push went through without the hook running anything — a green push proves nothing"
  else ok "$n"; fi
  drop_sandbox
}

t_hook_is_template_only() {  # D-T14
  local n="D-T14 pre-push hook is a TEMPLATE: nothing installed it into this repo"
  local hookfile="$REPO/.githooks/pre-push"
  local configured; configured="$(cd "$REPO" && git config --get core.hooksPath || true)"
  if [ ! -x "$hookfile" ]; then
    bad "$n" "$hookfile missing or not executable"
  elif [ -f "$REPO/.git/hooks/pre-push" ]; then
    bad "$n" "$REPO/.git/hooks/pre-push exists — the hook was installed, not offered"
  elif [ -n "$configured" ] && [ "$configured" != ".githooks" ]; then
    bad "$n" "core.hooksPath was pointed somewhere unexpected: $configured"
  else ok "$n"; fi
}

# ---- nightly runner ---------------------------------------------------------

t_nightly_default_report_path() {  # D-T15
  local n="D-T15 nightly-tests.sh: writes \$HOME/.pervio/test-reports/<date>.log, creating the dir"
  new_sandbox --with-e2e
  sb_run bash scripts/nightly-tests.sh
  local log; log="$(report_log "$SB/home/.pervio/test-reports")"
  if [ -z "$log" ]; then
    bad "$n" "no <date>.log under \$HOME/.pervio/test-reports (found: $(ls -1 "$SB/home/.pervio/test-reports" 2>/dev/null | tr '\n' ' ')); out: $(sb_out | tail -5 | tr '\n' ' ')"
  elif ! grep -q 'RESULT: PASS' "$log"; then
    bad "$n" "the log does not contain the run's verdict; log tail: $(tail -3 "$log" | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_nightly_failure_is_logged_and_returned() {  # D-T16
  local n="D-T16 nightly-tests.sh: exit code mirrors the failure and the log keeps the evidence"
  new_sandbox --with-e2e
  STUB_SERVER_EXIT=1 sb_run bash scripts/nightly-tests.sh
  local log; log="$(report_log "$SB/home/.pervio/test-reports")"
  if [ "$(sb_code)" = 0 ]; then
    bad "$n" "exit 0 while the server suite failed — launchd would never notice"
  elif [ -z "$log" ]; then
    bad "$n" "no log written on failure (the one run you actually need)"
  elif ! grep -q 'STUB-SERVER-FAILED-MARKER' "$log"; then
    bad "$n" "the failing suite's output is not in the log; tail: $(tail -5 "$log" | tr '\n' ' ')"
  elif ! grep -q 'RESULT: FAIL' "$log"; then
    bad "$n" "the log does not record a FAIL verdict; tail: $(tail -3 "$log" | tr '\n' ' ')"
  else ok "$n"; fi
  drop_sandbox
}

t_nightly_report_dir_override() {  # D-T17
  local n="D-T17 nightly-tests.sh: PERVIO_TEST_REPORT_DIR redirects the log (so tests never touch ~/.pervio)"
  new_sandbox --with-e2e
  local alt="$SB/altreports"
  ( cd "$SB/repo" && env PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$SB/home" \
      CALLS="$SB/calls" SB_TMP="$SB" PERVIO_TEST_REPORT_DIR="$alt" \
      bash scripts/nightly-tests.sh ) > "$SB/out.txt" 2>&1
  echo $? > "$SB/code.txt"
  if [ -z "$(report_log "$alt")" ]; then
    bad "$n" "override ignored — no <date>.log under $alt"
  elif [ -n "$(report_log "$SB/home/.pervio/test-reports")" ]; then
    bad "$n" "wrote to the default path anyway despite the override"
  else ok "$n"; fi
  drop_sandbox
}

# ---- launchd template -------------------------------------------------------

PLIST="$REPO/scripts/launchd/app.pervio.nightly-tests.plist.template"
LABEL="app.pervio.nightly-tests"

t_plist_valid_and_uninstalled() {  # D-T18
  local n="D-T18 launchd plist template: valid plist, right Label, and NOT installed"
  if [ ! -f "$PLIST" ]; then
    bad "$n" "missing $PLIST"
  elif ! plutil -lint "$PLIST" >/dev/null 2>&1; then
    bad "$n" "plutil -lint rejects it: $(plutil -lint "$PLIST" 2>&1 | tail -2)"
  elif ! grep -q "<string>$LABEL</string>" "$PLIST"; then
    bad "$n" "Label is not $LABEL"
  elif ! grep -q '__REPO__' "$PLIST"; then
    bad "$n" "no __REPO__ placeholder — a template must not bake one machine's path in"
  elif ls "$HOME/Library/LaunchAgents/$LABEL.plist" >/dev/null 2>&1; then
    bad "$n" "$HOME/Library/LaunchAgents/$LABEL.plist EXISTS — the job was installed, not offered"
  elif ! grep -q 'nightly-tests.sh' "$PLIST"; then
    bad "$n" "the job does not point at scripts/nightly-tests.sh"
  else ok "$n"; fi
}

t_plist_renders_and_runs() {  # D-T19
  local n="D-T19 launchd template: substituting __REPO__ yields a plist that runs the real runner"
  new_sandbox --with-e2e
  if [ ! -f "$PLIST" ]; then bad "$n" "missing $PLIST"; drop_sandbox; return; fi
  local rendered="$SB/rendered.plist"
  sed "s|__REPO__|$SB/repo|g" "$PLIST" > "$rendered"
  if ! plutil -lint "$rendered" >/dev/null 2>&1; then
    bad "$n" "rendered plist is invalid: $(plutil -lint "$rendered" 2>&1 | tail -2)"
    drop_sandbox; return
  fi
  # Pull ProgramArguments out of the rendered plist and actually execute them.
  local prog
  prog="$(plutil -extract ProgramArguments json -o - "$rendered" 2>/dev/null)"
  if [ -z "$prog" ]; then
    bad "$n" "no ProgramArguments in the plist"; drop_sandbox; return
  fi
  local argv=(); while IFS= read -r line; do argv+=("$line"); done < <(
    printf '%s' "$prog" | python3 -c 'import json,sys; [print(a) for a in json.load(sys.stdin)]' )
  if [ "${#argv[@]}" -lt 2 ]; then
    bad "$n" "ProgramArguments too short: $prog"; drop_sandbox; return
  fi
  if [ ! -x "${argv[0]}" ] && ! command -v "${argv[0]}" >/dev/null 2>&1; then
    bad "$n" "argv[0] is not runnable: ${argv[0]}"; drop_sandbox; return
  fi
  ( cd "$SB/repo" && env PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$SB/home" \
      CALLS="$SB/calls" SB_TMP="$SB" "${argv[@]}" ) > "$SB/out.txt" 2>&1
  echo $? > "$SB/code.txt"
  if [ "$(sb_code)" != 0 ]; then
    bad "$n" "the plist's own command failed on a green sandbox (exit $(sb_code)): $(sb_out | tail -5 | tr '\n' ' ')"
  elif [ -z "$(report_log "$SB/home/.pervio/test-reports")" ]; then
    bad "$n" "the plist's command produced no nightly report"
  else ok "$n"; fi
  drop_sandbox
}

# ---- docs -------------------------------------------------------------------

DOC="$REPO/docs/testing.md"

t_doc_covers_the_commands() {  # D-T20
  local n="D-T20 docs/testing.md: carries the install/uninstall/regenerate commands, not just prose"
  if [ ! -f "$DOC" ]; then bad "$n" "missing $DOC"; return; fi
  local missing=()
  grep -q 'scripts/test-fast.sh'                 "$DOC" || missing+=("test-fast.sh")
  grep -q 'scripts/test-all.sh'                  "$DOC" || missing+=("test-all.sh")
  grep -q 'core.hooksPath .githooks'             "$DOC" || missing+=("git config core.hooksPath .githooks")
  grep -q 'launchctl bootstrap'                  "$DOC" || missing+=("launchctl bootstrap")
  grep -q 'launchctl bootout'                    "$DOC" || missing+=("launchctl bootout (uninstall)")
  grep -q 'export_fixtures.py'                   "$DOC" || missing+=("fixture regeneration")
  grep -q 'server/tests/run_all.sh'              "$DOC" || missing+=("run_all.sh")
  grep -q '~/.pervio/test-reports'               "$DOC" || missing+=("report path")
  grep -q -- '--no-verify'                       "$DOC" || missing+=("hook bypass")
  if [ "${#missing[@]}" -gt 0 ]; then
    bad "$n" "not documented: ${missing[*]}"
  else ok "$n"; fi
}

t_doc_label_matches_plist() {  # D-T21
  local n="D-T21 docs/testing.md: the launchctl label/filename it tells you to use matches the template"
  if [ ! -f "$DOC" ] || [ ! -f "$PLIST" ]; then bad "$n" "missing doc or plist"; return; fi
  if ! grep -q "$LABEL" "$DOC"; then
    bad "$n" "doc never mentions the job label $LABEL — copy/paste would target the wrong job"
  elif ! grep -q "LaunchAgents/$LABEL.plist" "$DOC"; then
    bad "$n" "doc does not name ~/Library/LaunchAgents/$LABEL.plist"
  elif ! grep -q '__REPO__' "$DOC"; then
    bad "$n" "doc does not tell you to substitute __REPO__"
  else ok "$n"; fi
}

# ------------------------------------------------------------------- main ----
echo "== track D: test-automation tests =="
t_fast_ios_failure_propagates
t_fast_server_failure_propagates
t_fast_green_runs_both_layers
t_fast_destination_from_simctl
t_fast_no_simulator_is_loud
t_fast_never_spends_quota
t_ios_unit_skips_are_not_a_pass
t_ios_unit_names_what_went_unverified
t_ios_unit_unverified_optout_is_not_pass
t_ios_unit_no_skips_is_still_a_clean_pass
t_ios_unit_rotates_and_hands_over_the_stale_pin
t_ios_unit_negative_control_catches_a_self_certifying_test
t_ios_unit_negative_control_needs_the_right_red
t_ios_unit_skip_with_a_live_endpoint_is_red
t_ios_unit_clears_strays_after_the_run
t_ios_unit_hang_is_not_blamed_on_a_deleted_test
t_ios_unit_absent_transport_tests_are_red_without_an_endpoint
t_ios_unit_absent_transport_tests_are_red_with_an_endpoint
t_ios_unit_negative_control_retries_a_launch_flake
t_all_runs_smoke_no_quota
t_all_missing_e2e_is_honest
t_all_env_not_ready_is_skip
t_all_smoke_failure_is_red
t_smoke_exit_semantics
t_all_with_quota_flag
t_all_only_two_is_a_skip
t_all_runs_the_selftest
t_selftest_does_not_recurse
t_all_honors_skip_knobs
t_all_honors_skip_smoke
t_hook_blocks_failing_push
t_hook_allows_green_push
t_hook_is_template_only
t_nightly_default_report_path
t_nightly_failure_is_logged_and_returned
t_nightly_report_dir_override
t_plist_valid_and_uninstalled
t_plist_renders_and_runs
t_doc_covers_the_commands
t_doc_label_matches_plist

echo ""
if [ "$fail" -eq 0 ]; then
  echo "test_scripts.sh: ALL $pass PASSED"
  exit 0
else
  echo "test_scripts.sh: $pass passed, $fail FAILED"
  for f in "${failed_names[@]}"; do echo "   - $f"; done
  exit 1
fi
