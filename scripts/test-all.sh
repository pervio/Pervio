#!/usr/bin/env bash
# Everything: the two fast layers plus the end-to-end iOS smoke (track C). This
# is what the nightly job runs.
#
#     bash scripts/test-all.sh                # no model quota is spent
#     bash scripts/test-all.sh --with-quota   # ALSO the real-agent server e2e suites
#
# Exit 0 iff nothing failed. A layer whose prerequisites are absent (track C not
# installed, no sshd, no simulator for it) is SKIPPED, printed with its reason,
# and counted in the summary — never quietly folded into "passed".
#
# PERVIO_SKIP_IOS / PERVIO_SKIP_SERVER / PERVIO_SKIP_SMOKE=1 skip a layer by hand
# (also as SKIP, never as a pass) — useful when layer 3's sshd port or the
# simulator is already busy with something else.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/layers.sh"

WITH_QUOTA=0
for a in "$@"; do
  case "$a" in
    --with-quota) WITH_QUOTA=1;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown flag: $a" >&2; exit 2;;
  esac
done

echo "pervio test-all — $(date '+%Y-%m-%d %H:%M:%S')  (logs: $LOG_DIR)"

layer_scripts_selftest

if [ "${PERVIO_SKIP_IOS:-0}" = 1 ]; then
  skip_layer ios-unit "PERVIO_SKIP_IOS=1"
else
  layer_ios_unit
fi

if [ "${PERVIO_SKIP_SERVER:-0}" = 1 ]; then
  skip_layer server-suites "PERVIO_SKIP_SERVER=1"
elif [ "$WITH_QUOTA" = 1 ]; then
  layer_server_quota_e2e     # run_all.sh --e2e is a superset of the no-cost suites
else
  layer_server_suites
  echo ""
  echo "(the real-agent server e2e suites did not run — pass --with-quota to spend model quota on them)"
fi

if [ "${PERVIO_SKIP_SMOKE:-0}" = 1 ]; then
  skip_layer ios-ui-smoke "PERVIO_SKIP_SMOKE=1"
else
  layer_ios_ui_smoke
fi

summary
