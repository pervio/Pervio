#!/usr/bin/env bash
# The screens the website, the README and the App Store listing show: the real
# pages of the app, staged by ios/Tests/Render/SiteShotsTests.swift in a 6.9"
# simulator and photographed from outside, so the status bar and the home
# indicator are the system's own.
#
#     bash scripts/site-shots.sh [FULLDIR]
#
# Full-size pictures (1320×2868, what the App Store asks of a 6.9" phone) go to
# FULLDIR (default: ios/DerivedData/site-shots, git-ignored); a copy 720 px
# wide — twice what the site ever shows a phone at — goes to web/assets/shots.
#
# Knobs:  PERVIO_SHOTS_UDID   the simulator to use (default: a booted
#                             "iPhone 16 Pro Max")
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/ios/DerivedData/site-shots}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
WEB="$ROOT/web/assets/shots"
MARKER="$ROOT/ios/Tests/Fixtures/snapshots/.shots"
LOG="${TMPDIR:-/tmp}/pervio-site-shots.$$.log"

UDID="${PERVIO_SHOTS_UDID:-$(xcrun simctl list devices booted | sed -n 's/.*iPhone 16 Pro Max[^(]*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -1)}"
if [ -z "$UDID" ]; then
  echo "no booted iPhone 16 Pro Max simulator — boot one, or set PERVIO_SHOTS_UDID" >&2; exit 1
fi

mkdir -p "$OUT"; rm -f "$OUT"/*.ready "$OUT/ALL.done"
cleanup() {
  rm -f "$MARKER" "$OUT"/*.ready "$OUT/ALL.done"
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1
  [ -n "${XB:-}" ] && kill "$XB" 2>/dev/null
  pkill -f "PervioWidgets.appex" 2>/dev/null
}
trap cleanup EXIT

# The clock every product page uses, a full battery, full bars; dark, as most
# people run the app.
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi >/dev/null 2>&1

( cd "$ROOT/ios" && xcodegen generate >/dev/null ) || exit 1
printf '%s\n' "$OUT" > "$MARKER"
xcodebuild test -project "$ROOT/ios/Pervio.xcodeproj" -scheme Pervio -destination "id=$UDID" \
  -derivedDataPath "$ROOT/ios/DerivedData" -only-testing:PervioTests/SiteShotsTests \
  CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1 &
XB=$!

n=0
while kill -0 "$XB" 2>/dev/null && [ ! -e "$OUT/ALL.done" ]; do
  for r in "$OUT"/*.ready; do
    [ -e "$r" ] || continue
    name="$(basename "$r" .ready)"
    if xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.tmp.png" >/dev/null 2>&1; then
      mv "$OUT/$name.tmp.png" "$OUT/$name.png"; n=$((n+1)); echo "shot $name"
      # the test removes the .ready once it has seen the picture
      for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$r" ] || break; sleep 0.2; done
    fi
  done
  sleep 0.2
done
sleep 2; kill "$XB" 2>/dev/null
echo "$n screens in $OUT"
mkdir -p "$WEB"
for f in "$OUT"/*.png; do
  [ -e "$f" ] || continue
  sips --resampleWidth 720 "$f" --out "$WEB/$(basename "$f")" >/dev/null 2>&1
done
echo "web copies (720 px wide) in $WEB"
grep -E "error:|XCTAssert|Executed [0-9]+ tests" "$LOG" | grep -v "aps-environment" | cut -c1-220 | tail -5
[ "$n" -gt 0 ]
