#!/usr/bin/env bash
# What the nightly launchd job runs. Wraps scripts/test-all.sh so the whole run —
# verdict included — lands in a dated log you can read the next morning:
#
#     ~/.pervio/test-reports/<YYYY-MM-DD>.log
#
#     bash scripts/nightly-tests.sh              # same flags as test-all.sh
#     PERVIO_TEST_REPORT_DIR=/tmp/x bash scripts/nightly-tests.sh
#
# Exit code mirrors test-all.sh, so `launchctl kickstart -p` and any wrapper see
# a red night as red. Appends (a second run the same day does not erase the
# first) and prunes reports older than PERVIO_TEST_REPORT_KEEP_DAYS (default 30).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPORT_DIR="${PERVIO_TEST_REPORT_DIR:-$HOME/.pervio/test-reports}"
mkdir -p "$REPORT_DIR" || { echo "cannot create $REPORT_DIR" >&2; exit 2; }
LOG="$REPORT_DIR/$(date +%Y-%m-%d).log"

_run() {
  echo "############################################################"
  echo "# pervio nightly — started $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# repo:  $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'no git'))"
  echo "############################################################"
  bash "$ROOT/scripts/test-all.sh" "$@"
  local rc=$?
  echo "# pervio nightly — finished $(date '+%Y-%m-%d %H:%M:%S %Z'), exit $rc"
  return "$rc"
}

_run "$@" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}      # tee's exit code is not the verdict

find "$REPORT_DIR" -name '*.log' -type f -mtime "+${PERVIO_TEST_REPORT_KEEP_DAYS:-30}" -delete 2>/dev/null

echo "report: $LOG (exit $rc)"
exit "$rc"
