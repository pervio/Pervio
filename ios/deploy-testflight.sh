#!/bin/bash
# Archive Pervio and upload it to TestFlight, authenticated by an App Store
# Connect API key — no Apple ID password, no Xcode GUI, no cable.
#
# One-time setup (files live OUTSIDE the repo; the .p8 is a secret):
#   ~/.pervio-dev/asc/AuthKey_<KEYID>.p8   the key downloaded from App Store Connect
#   ~/.pervio-dev/asc/key_id               the 10-char Key ID
#   ~/.pervio-dev/asc/issuer_id            the Issuer ID (UUID)
# and two values of YOUR app, in the git-ignored ios/Signing.local.xcconfig
# (or the environment):
#   DEVELOPMENT_TEAM   = your 10-char Team ID            (signing, export options)
#   PERVIO_ASC_APP_ID  = the app's numeric Apple ID      (altool; `xcrun altool --list-apps` shows it)
#
# Usage:  ios/deploy-testflight.sh            archive, export, upload
#         ios/deploy-testflight.sh --check    resolve every input, upload nothing
# The build number is the UTC timestamp, so every upload is strictly newer —
# no state file to forget, no collision on reruns.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_DIR="$HOME/.pervio-dev/asc"
KEY_ID="$(cat "$KEY_DIR/key_id" 2>/dev/null || true)"
ISSUER_ID="$(cat "$KEY_DIR/issuer_id" 2>/dev/null || true)"
KEY_FILE="$KEY_DIR/AuthKey_${KEY_ID}.p8"
if [[ -z "$KEY_ID" || -z "$ISSUER_ID" || ! -f "$KEY_FILE" ]]; then
  echo "missing API key material — expected:" >&2
  echo "  $KEY_DIR/key_id, $KEY_DIR/issuer_id, $KEY_DIR/AuthKey_<KEYID>.p8" >&2
  exit 2
fi

# Values that are yours, not the project's: read from the local signing file
# unless the environment already says.
local_value() {  # $1 = key in ios/Signing.local.xcconfig
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\\([^[:space:]/]*\\).*/\\1/p" ios/Signing.local.xcconfig 2>/dev/null | tail -1
}
TEAM_ID="${DEVELOPMENT_TEAM:-$(local_value DEVELOPMENT_TEAM)}"
APP_APPLE_ID="${PERVIO_ASC_APP_ID:-$(local_value PERVIO_ASC_APP_ID)}"
if [[ -z "$TEAM_ID" || -z "$APP_APPLE_ID" ]]; then
  echo "missing DEVELOPMENT_TEAM or PERVIO_ASC_APP_ID — set both in ios/Signing.local.xcconfig" >&2
  exit 2
fi

BUILD="$(date -u +%Y%m%d%H%M)"
ARCHIVE="/tmp/pervio-${BUILD}.xcarchive"
EXPORT_DIR="/tmp/pervio-export-${BUILD}"
# The export options with the team filled in (the tracked file carries a placeholder).
EXPORT_PLIST="$(mktemp -t pervio-export-options).plist"
sed "s/__DEVELOPMENT_TEAM__/${TEAM_ID}/" ios/ExportOptions.plist > "$EXPORT_PLIST"
trap 'rm -f "$EXPORT_PLIST"' EXIT

if [[ "${1:-}" == "--check" ]]; then
  plutil -lint "$EXPORT_PLIST" >/dev/null
  echo "key:      $KEY_FILE (id ${KEY_ID:0:3}…)"
  echo "team:     ${TEAM_ID:0:3}… (${#TEAM_ID} chars)"
  echo "app id:   ${APP_APPLE_ID:0:3}… (${#APP_APPLE_ID} digits)"
  echo "export:   $(/usr/libexec/PlistBuddy -c 'Print :method' "$EXPORT_PLIST"), team filled: $(grep -c "$TEAM_ID" "$EXPORT_PLIST")"
  echo "check ok — nothing archived, nothing uploaded"
  exit 0
fi

echo "== archive (build ${BUILD}) =="
xcodebuild -project ios/Pervio.xcodeproj -scheme Pervio \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" archive \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_FILE" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" > /tmp/pervio-tf-archive.log 2>&1 \
  || { echo "ARCHIVE FAILED — last 30 lines of /tmp/pervio-tf-archive.log:"; tail -30 /tmp/pervio-tf-archive.log; exit 65; }
tail -1 /tmp/pervio-tf-archive.log

echo "== export ipa =="
# Two-step on purpose: xcodebuild's destination=upload path sometimes rides
# Xcode's GUI account session and dies with "Account credentials have expired"
# even when handed a perfectly valid API key. Export locally, then upload with
# altool, which authenticates with the key alone and never touches Xcode's
# accounts.
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_FILE" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" > /tmp/pervio-tf-upload.log 2>&1 \
  || { echo "EXPORT FAILED — last 30 lines of /tmp/pervio-tf-upload.log:"; tail -30 /tmp/pervio-tf-upload.log; exit 65; }

echo "== upload to TestFlight (altool, pure API key) =="
mkdir -p "$HOME/.appstoreconnect/private_keys"
cp -f "$KEY_FILE" "$HOME/.appstoreconnect/private_keys/" && chmod 600 "$HOME/.appstoreconnect/private_keys/"*.p8
# Xcode 27's altool no longer resolves the App Store Connect record from the
# bundle id when authenticating with an API key — it fails with "Unable to
# find Apple ID for Bundle ID 'app.pervio' … or provide the Apple ID" even
# though `altool --list-apps` shows the app. So hand it the app's numeric
# Apple ID (constant for the life of the ASC record; shown by --list-apps) —
# PERVIO_ASC_APP_ID above.
xcrun altool --upload-app -f "$EXPORT_DIR"/*.ipa -t ios --apple-id "$APP_APPLE_ID" \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID" > /tmp/pervio-tf-altool.log 2>&1 \
  || { echo "UPLOAD FAILED — last 30 lines of /tmp/pervio-tf-altool.log:"; tail -30 /tmp/pervio-tf-altool.log; exit 65; }
grep -E "No errors uploading" /tmp/pervio-tf-altool.log | tail -1

rm -rf "$ARCHIVE" "$EXPORT_DIR"
echo "uploaded build ${BUILD} — App Store Connect processes it in ~5-15 min,"
echo "then it appears in TestFlight on the phone."

# Fire-and-forget: a push here is exactly the "long-running thing finished,
# you probably walked away" case pervio-push exists for. Never let a push
# failure (no key yet, no device token) fail the deploy itself. The copy
# follows the phone's synced language (~/.pervio/push/lang, written by the app
# beside its push token), like every other server-authored push.
PUSH_BIN="$HOME/.pervio/bin/pervio-push"
case "$(cat "$HOME/.pervio/push/lang" 2>/dev/null)" in
  en*) PUSH_TITLE="TestFlight upload done"
       PUSH_BODY="build ${BUILD} is processing — updatable in a few minutes" ;;
  *)   PUSH_TITLE="TestFlight 已上传"
       PUSH_BODY="build ${BUILD} 正在处理,几分钟后可更新" ;;
esac
[ -x "$PUSH_BIN" ] && "$PUSH_BIN" send --title "$PUSH_TITLE" \
  --body "$PUSH_BODY" --thread pervio-deploy >/dev/null 2>&1 || true
