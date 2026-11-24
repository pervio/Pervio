#!/usr/bin/env bash
# The loop you run before every push: iOS unit tests + the no-cost server suites.
# Minutes, not an hour. No model quota is spent — run_all.sh is called WITHOUT
# --e2e on purpose.
#
#     bash scripts/test-fast.sh
#
# Exit 0 iff both layers passed. Knobs:
#   PERVIO_SKIP_IOS=1      skip layer 1 (reported as SKIP, never as a pass)
#   PERVIO_SKIP_SERVER=1   skip layer 2
#   PERVIO_DESTINATION=…   override the simulator xcodebuild targets
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/layers.sh"

echo "pervio test-fast — $(date '+%Y-%m-%d %H:%M:%S')  (logs: $LOG_DIR)"

if [ "${PERVIO_SKIP_IOS:-0}" = 1 ]; then
  skip_layer ios-unit "PERVIO_SKIP_IOS=1"
else
  layer_ios_unit
fi

if [ "${PERVIO_SKIP_SERVER:-0}" = 1 ]; then
  skip_layer server-suites "PERVIO_SKIP_SERVER=1"
else
  layer_server_suites
fi

summary
