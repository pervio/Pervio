#!/usr/bin/env bash
# One command for the iOS end-to-end smoke test (track C).
#
#     bash server/tests/e2e_ios/run_smoke.sh            # sandbox up, run, sandbox down
#     bash server/tests/e2e_ios/run_smoke.sh --keep     # leave the sandbox up for triage
#     PERVIO_E2E_SIM="iPhone 17 Pro" bash …/run_smoke.sh
#
# Exit codes, kept distinct on purpose so an automated caller can tell "broken"
# from "not runnable here":
#     0  the smoke test RAN and PASSED
#     1  the smoke test ran and FAILED (or was skipped — a skip is not a pass)
#     2  environment not ready (no simulator / no sshd / port taken) — nothing ran
#
# WHY IT GENERATES A PROJECT. ios/project.yml now declares PervioUITests itself,
# but this run needs its own SCHEME (and must not disturb ios/Pervio.xcodeproj).
# So the runner builds a THROWAWAY project inside the sandbox — a spec that
# `include`s ios/project.yml verbatim and adds the PervioSmoke scheme — and
# points xcodebuild at that. The app sources, the app target, its settings and
# its packages are the repo's, not a copy. Nothing is written under ios/ and
# Pervio.xcodeproj is not touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
IOS="$REPO/ios"
SETUP="$HERE/setup.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

ROOT="$(bash "$SETUP" root)"
GEN="$ROOT/xcodegen"
# Build products and the SwiftPM checkout default to the sandbox (thrown away
# with it — a smoke test should not leave state behind). Point these at a durable
# path while iterating and the first run's ~4-minute cold build becomes ~40s:
#   PERVIO_E2E_DD=/tmp/pervio-smoke-dd PERVIO_E2E_SPM_DIR=/tmp/pervio-smoke-spm …
DD="${PERVIO_E2E_DD:-$ROOT/DerivedData}"
LOG="$ROOT/xcodebuild.log"
NONCE="smoke$(date +%s | tail -c 6)"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    warn "--keep: sandbox left at $ROOT (stop it with: bash $SETUP stop)"
  else
    bash "$SETUP" stop >/dev/null 2>&1
  fi
}

# ------------------------------------------------------- 1. environment gates

say "== 1/5  prerequisites =="
if ! command -v xcodebuild >/dev/null 2>&1; then
  warn "NOT READY: xcodebuild is missing (install Xcode + xcode-select)."
  exit 2
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  warn "NOT READY: xcodegen is missing (brew install xcodegen)."
  exit 2
fi
bash "$SETUP" check || exit 2

# A booted simulator if there is one (fastest, and what a human is looking at),
# otherwise any available iPhone. Printing the choice matters: a smoke test that
# silently picked a different device is a debugging trap.
SIM_UDID="$(PERVIO_E2E_SIM="${PERVIO_E2E_SIM:-}" python3 - <<'PY'
import json, os, subprocess, sys
want = os.environ.get("PERVIO_E2E_SIM", "")
raw = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                     capture_output=True, text=True)
data = json.loads(raw.stdout or "{}").get("devices", {})
phones = [d for rt, ds in data.items() if "iOS" in rt for d in ds
          if d.get("isAvailable") and "iPhone" in d.get("name", "")]
if want:
    phones = [d for d in phones if d["name"] == want]
booted = [d for d in phones if d.get("state") == "Booted"]
pick = (booted or phones)
if not pick:
    sys.exit(1)
print(pick[0]["udid"] + "\t" + pick[0]["name"] + "\t" + pick[0].get("state", "?"))
PY
)" || { warn "NOT READY: no available iPhone simulator (open Xcode > Settings > Components)."; exit 2; }
SIM_ID="${SIM_UDID%%$'\t'*}"
say "  simulator   ${SIM_UDID#*$'\t'} ($SIM_ID)"
# Boot it (no-op when already booted) and wait until it is actually usable, then
# clear any instance a previous run left behind. Without this, a simulator that
# is half-booted or still holding a stale app swallows the launch and xcodebuild
# waits forever — seen 2026-08-07: "Launch app.pervio" and then nothing for 20
# minutes.
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1
xcrun simctl terminate "$SIM_ID" app.pervio >/dev/null 2>&1 || true

# ------------------------------------------------------- 2. hermetic endpoint

say ""
say "== 2/5  hermetic sshd + temp HOME + shim =="
# Exit 1, not 2: the sandbox failing to START is OUR code breaking (setup.sh,
# sshd config, the temp HOME), not a missing external prerequisite. Reporting it
# as "not ready" would let the layer runner file it as SKIP and the whole run
# would still say PASS — a broken harness must never read as green.
bash "$SETUP" start || { warn "FAILED: the sandbox would not start — see $ROOT/sshd.log"; exit 1; }
trap cleanup EXIT

# Server-side proof BEFORE the app is involved. If this is red the iOS failure
# that follows would be noise.
PERVIO_E2E_NONCE="${NONCE}srv" bash "$SETUP" verify || {
  # This runs the REPO'S OWN pervio-chat over a real SSH connection. If it cannot
  # complete a turn, that is a production regression — the single most important
  # thing this whole harness exists to catch. Exit 1 so it is a FAILURE; calling
  # it "not ready" would bury a broken chat pipeline inside a green summary.
  warn "FAILED: pervio-chat could not complete a turn in the sandbox — see $ROOT/sshd.log"
  exit 1
}

CONFIG_B64="$(bash "$SETUP" config-b64)" \
  || { warn "FAILED: could not read the sandbox profile (setup.sh config-b64)"; exit 1; }

# ------------------------------------------------------- 3. throwaway project

say ""
say "== 3/5  throwaway Xcode project (ios/project.yml + a UI-test target) =="
rm -rf "$GEN"; mkdir -p "$GEN"
# Symlinks, not copies: the included spec's relative source paths ("Sources",
# "Tests", "LiveActivity") resolve here, and every file the compiler opens is the
# repo's own. (`relativePaths: false` is what makes the include resolve against
# THIS directory; `true` deadlocks XcodeGen 2.45.)
for dir in Sources Tests LiveActivity UITests; do
  [ -d "$IOS/$dir" ] && ln -s "$IOS/$dir" "$GEN/$dir"
done
# The design render harness sits OUTSIDE ios/ (its target's source path is
# "../design/render"), so that one resolves a level up from $GEN. Without this
# link XcodeGen refuses the whole spec — including the app target — over a
# target the smoke test never builds.
[ -d "$REPO/design" ] && ln -sfn "$REPO/design" "$(dirname "$GEN")/design"
# The app bundles the server scripts and templates as folder references
# ("../server/bin", "../server/templates" — the app carries its own server),
# resolved a level up from $GEN like the design harness; and its targets take
# their signing settings from ios/Signing.xcconfig, resolved against $GEN.
ln -sfn "$REPO/server" "$(dirname "$GEN")/server"
[ -f "$IOS/Signing.xcconfig" ] && ln -sf "$IOS/Signing.xcconfig" "$GEN/Signing.xcconfig"
cat > "$GEN/project.yml" <<YML
# Generated by server/tests/e2e_ios/run_smoke.sh — throwaway, never committed.
name: Pervio
include:
  - path: $IOS/project.yml
    relativePaths: false
# NO PervioUITests stanza here any more: ios/project.yml declares that target
# itself now (the header above describes the old world). Re-declaring it made
# XcodeGen refuse the whole spec — "Target PervioUITests has the dependency
# Pervio multiple times" — because an included target MERGES with a local one of
# the same name. All this spec still adds is the smoke scheme.
schemes:
  PervioSmoke:
    build:
      targets:
        Pervio: all
        PervioUITests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - PervioUITests
YML
( cd "$GEN" && xcodegen generate --spec "$GEN/project.yml" --project "$GEN" ) </dev/null \
  || { warn "FAILED: xcodegen rejected the throwaway spec (our spec, not your machine)"; exit 1; }

# ------------------------------------------------------------ 4. run the test

say ""
say "== 4/5  xcodebuild test (nonce $NONCE) =="
say "  log $LOG"
rm -rf "$ROOT/smoke.xcresult"   # xcodebuild refuses to overwrite a result bundle
# NOTE: do NOT add CODE_SIGNING_ALLOWED=NO here. The simulator's ad-hoc signature
# is what gives the app its application-identifier entitlement, and without that
# entitlement SecItemAdd fails — the seeded private key silently never reaches
# the Keychain and the app reports "Couldn't parse the private key". Observed,
# not theorized: that flag turned this smoke test red for exactly that reason.
XCB_EXTRA=()   # expanded as ${XCB_EXTRA[@]+"${XCB_EXTRA[@]}"}: an empty array is "unbound" under set -u on bash 3.2
if [ -n "${PERVIO_E2E_SPM_DIR:-}" ]; then
  mkdir -p "$PERVIO_E2E_SPM_DIR"
  XCB_EXTRA+=(-clonedSourcePackagesDirPath "$PERVIO_E2E_SPM_DIR")
fi
# TEST_RUNNER_<VAR> is xcodebuild's supported channel into the UI-test runner's
# environment; the prefix is stripped on the way in.
# SwiftPM resolves packages through git, and a host whose global config sets
# `safe.bareRepository = explicit` makes every cached bare clone unusable —
# "fatal: cannot use bare repository ... (safe.bareRepository is 'explicit')",
# which xcodebuild reports as "Could not resolve package dependencies" (seen on
# this machine 2026-08-07). GIT_CONFIG_* overrides that for THIS process tree
# only; the user's own git config is never touched.
TEST_RUNNER_PERVIO_E2E_CONFIG_B64="$CONFIG_B64" \
TEST_RUNNER_PERVIO_E2E_NONCE="$NONCE" \
TEST_RUNNER_PERVIO_E2E_HOME="$ROOT/home" \
TEST_RUNNER_PERVIO_E2E_HTTP_PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$ROOT/http.json" 2>/dev/null)" \
TEST_RUNNER_PERVIO_E2E_HTTP_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$ROOT/http.json" 2>/dev/null)" \
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
xcodebuild test \
  -project "$GEN/Pervio.xcodeproj" \
  -scheme PervioSmoke \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$ROOT/smoke.xcresult" \
  -only-testing:"${PERVIO_E2E_ONLY:-PervioUITests}" \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 420 \
  ${XCB_EXTRA[@]+"${XCB_EXTRA[@]}"} \
  > "$LOG" 2>&1 &
XCB_PID=$!
# Wall-clock watchdog on top of -maximum-test-execution-time-allowance: that flag
# bounds a hung TEST, this bounds a hung BUILD or a launch that never returns.
# macOS has no coreutils `timeout`.
DEADLINE=$(( $(date +%s) + ${PERVIO_E2E_TIMEOUT:-1800} ))
while kill -0 "$XCB_PID" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    warn "TIMEOUT: xcodebuild exceeded ${PERVIO_E2E_TIMEOUT:-1800}s — killing it."
    kill -9 "$XCB_PID" 2>/dev/null
    wait "$XCB_PID" 2>/dev/null
    tail -30 "$LOG" >&2
    exit 1
  fi
  sleep 5
done
wait "$XCB_PID"
BUILD_RC=$?

# ---------------------------------------------------------------- 5. verdict

say ""
say "== 5/5  verdict =="
grep -E "^(Test Case|Test Suite .*(passed|failed)|.*error:)" "$LOG" | tail -20

# A skip is not a pass. The guard was born when the suite was ONE flow (a skip
# meant "never reached the server", 2026-08-07); now that there are nine, a
# flow that skips on a sandbox condition (the digest flow when no publication
# is seeded) must not veto a run in which every other flow passed (2026-10-16).
# So: the round-trip flow (or, narrowed, the chosen flow) must have PASSED, a
# run in which nothing passed fails, and every other skip is named out loud.
# Both spellings on purpose: Xcode 26 logs "Test Case '…' skipped (0.1 seconds)",
# older toolchains log "… was skipped".
core="${PERVIO_E2E_ONLY:-PervioUITests/SmokeTests/testTypedMessageRoundTripsThroughRealSSHAndRendersTheReply}"
core="${core##*/}"
if grep -qE "' skipped|was skipped" "$LOG"; then
  if ! grep -q "$core.*' passed" "$LOG"; then
    warn "FAIL: the smoke's core flow ($core) did not pass — a skip there means it never reached the server."
    grep -B2 -A6 -E "' skipped|was skipped" "$LOG" | head -40 >&2
    exit 1
  fi
  warn "note: some flow(s) SKIPPED on a sandbox condition (not a pass, not a veto):"
  grep -E "' skipped|was skipped" "$LOG" | sed 's/^/    /' >&2
  grep -B6 -E "' skipped|was skipped" "$LOG" | grep -E "XCTSkip|skip" | head -6 | sed 's/^/    /' >&2
fi
# The provider flow's server-side half: its two turns (before leaving the
# conversation and after re-entering it) must BOTH have reached the agent with
# the sandbox vendor's base URL — the badge saying "E2E Vendor" is not enough,
# the command the phone sent has to carry --provider too. Checked only when
# that test ran, so narrowing with PERVIO_E2E_ONLY keeps the verdict honest.
# A LIVING run (2026-10-21): in Run mode the turn after re-entry is FED into
# the process the first turn started — one agent start, two turns, the vendor's
# URL on that one process. Then one start carrying it is the whole story,
# provided both turns' replies sit in ONE run's output (its out.jsonl carries
# both nonces); a chat-mode flow still needs two starts.
if grep -q "testProviderPickedInTheBadgeSurvivesLeavingAndReenteringTheConversation.*passed" "$LOG"; then
  n="$(grep -c 'e2e.invalid/anthropic' "$ROOT/shim_env.log" 2>/dev/null || echo 0)"
  fed=0
  for f in "$ROOT"/home/.pervio/runs/*/out.jsonl; do
    [ -f "$f" ] || continue
    if grep -q "${NONCE}pv1" "$f" && grep -q "${NONCE}pv2" "$f"; then fed=1; fi
  done
  if [ "${n:-0}" -lt 2 ] && ! { [ "${n:-0}" -ge 1 ] && [ "$fed" -eq 1 ]; }; then
    warn "FAIL: the provider flow passed on screen but only $n agent start(s) carried the vendor's URL (need 2 — before and after re-entry — or 1 whose living process answered both turns) — see $ROOT/shim_env.log"
    exit 1
  fi
  if [ "$fed" -eq 1 ]; then
    say "  provider overlay reached the agent on $n start(s); the re-entry turn was fed into that living process (one run, both replies)"
  else
    say "  provider overlay reached the agent on $n turns (shim_env.log)"
  fi
fi
if grep -q "' passed" "$LOG" && [ "$BUILD_RC" -eq 0 ]; then
  say "SMOKE PASSED — the app talked to a real sshd and rendered the server's reply."
  exit 0
fi
warn "SMOKE FAILED (xcodebuild rc=$BUILD_RC). Last lines of $LOG:"
tail -40 "$LOG" >&2
exit 1
