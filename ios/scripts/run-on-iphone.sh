#!/usr/bin/env bash
# Signed development build and install for a connected, trusted iPhone.
# Xcode manages signing; never store keys, tokens or Apple profiles in this repo.
set -euo pipefail

usage() {
  cat <<'HELP'
MP3 Shelf — signed iPhone installation

Usage:
  MP3SHELF_TEAM_ID=YOUR10CHARTEAMID bash ios/scripts/run-on-iphone.sh DEVICE_UDID

Find your connected device:
  xcrun devicectl list devices

First sign into Xcode > Settings > Accounts, and trust/unlock the iPhone.
Enable Developer Mode if prompted and find the Apple team ID in Xcode.
This script signs the Debug app with automatic signing, checks the signature,
installs it on the chosen physical iPhone and launches it.

Outputs are local and Git-ignored under ios/build/iphone-device/.
This does NOT submit to TestFlight or perform real-life audio acceptance tests.
HELP
}
if [[ "$#" -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  if [[ "$#" -eq 0 ]]; then exit 2; else exit 0; fi
fi

DEVICE_ID="$1"
TEAM_ID="$(printenv MP3SHELF_TEAM_ID 2>/dev/null || true)"
if [[ -z "$DEVICE_ID" || ! "$TEAM_ID" =~ ^[A-Za-z0-9]{10}$ ]]; then
  echo "ERROR: Provide your physical device UDID and valid 10-character Apple team ID." >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: A Mac with full Xcode is required for Apple signing and installation." >&2
  exit 2
fi
for executable in xcodebuild xcrun codesign git; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "ERROR: Missing executable: $executable" >&2
    exit 2
  fi
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$ROOT/ios/build/iphone-device"
DERIVED="$OUTPUT/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphoneos/MP3Shelf.app"
BUNDLE_ID="$(printenv MP3SHELF_BUNDLE_ID 2>/dev/null || echo com.jonnyt.mp3shelf)"
mkdir -p "$OUTPUT"

echo "Checking iPhone connection: $DEVICE_ID"
if ! xcrun devicectl device info details --device "$DEVICE_ID" > "$OUTPUT/device-info.txt" 2>&1; then
  echo "ERROR: Device unavailable. Check trust, unlock, Developer Mode and USB." >&2
  cat "$OUTPUT/device-info.txt" >&2
  exit 3
fi

echo "Building with Apple automatic development signing (team $TEAM_ID)"
xcodebuild \
  -project "$ROOT/ios/MP3Shelf.xcodeproj" \
  -scheme MP3Shelf \
  -configuration Debug \
  -sdk iphoneos \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build 2>&1 | tee "$OUTPUT/build.log"

if [[ ! -d "$APP" || ! -f "$APP/embedded.mobileprovision" ]]; then
  echo "ERROR: Xcode did not produce a provisioned device app." >&2
  exit 4
fi
if ! codesign --verify --deep --strict --verbose=2 "$APP" > "$OUTPUT/signature-check.log" 2>&1; then
  cat "$OUTPUT/signature-check.log" >&2
  echo "ERROR: App signature verification failed." >&2
  exit 4
fi
codesign -dv --verbose=4 "$APP" > "$OUTPUT/signature-metadata.txt" 2>&1 || true

echo "Installing signed app on $DEVICE_ID"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | tee "$OUTPUT/install.log"
echo "Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | tee "$OUTPUT/launch.log"

COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$OUTPUT/QA_RECORD.md" <<RECORD
# MP3 Shelf — physical-device installation evidence

- Date (UTC): $DATE
- Source commit: $COMMIT
- Physical device model / iOS version: FILL IN
- Signed development build: PASS
- Provisioning profile and app signature verification: PASS
- Device app installation: PASS
- Process launch request: PASS
- Offline MP3 playback in Airplane Mode: NOT TESTED
- Lock Screen / Control Center / Bluetooth playback: NOT TESTED
- Spotify playlist API / OAuth: NOT TESTED
- Authorized MP3 lookup and actual download: NOT TESTED
- Network interruption / iOS background download: NOT TESTED
- Backup restore and low-storage behavior: NOT TESTED
- VoiceOver / Dynamic Type: NOT TESTED
- Reported defects and user acceptance: FILL IN

Do not mark TestFlight/App Store or hardware audio acceptance complete.
See ios/DEVICE_QA.md for the manual end-to-end tests.
RECORD

echo "SIGNED DEVELOPMENT BUILD, INSTALLATION AND LAUNCH REQUEST SUCCEEDED."
echo "Device QA evidence: $OUTPUT/QA_RECORD.md"
echo "Continue with ios/DEVICE_QA.md on the real device."
