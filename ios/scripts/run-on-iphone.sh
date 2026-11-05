#!/usr/bin/env bash
# Local signed build. Xcode owns provisioning; this script never exports keys.
set -euo pipefail

usage() {
  cat <<'HELP'
MP3 Shelf — signed device build and diagnostics

Install and launch:
  MP3SHELF_TEAM_ID=YOUR10CHARTEAMID bash ios/scripts/run-on-iphone.sh DEVICE_UDID

Build/sign only, using the team selected in this project:
  bash ios/scripts/run-on-iphone.sh --diagnose

Diagnostic mode never installs or launches. An optional MP3SHELF_TEAM_ID
can override the project's team. Sign into Xcode Settings > Accounts first.
For installation, connect, unlock and trust your iPhone and enable Developer Mode.
Outputs: ios/build/iphone-device/QA_RECORD.md and isolated runs/ folders.
HELP
}
if [[ "$#" -eq 0 || "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  if [[ "$#" -eq 0 ]]; then exit 2; else exit 0; fi
fi
MODE=install
if [[ "$1" == --diagnose ]]; then MODE=diagnose; shift; fi
if [[ "$#" -gt 1 || ( "$MODE" == install && "${1:-}" == -* ) ]]; then usage >&2; exit 2; fi
DEVICE_ID="${1:-}"
TEAM_ID="$(printenv MP3SHELF_TEAM_ID 2>/dev/null || true)"
if [[ ( "$MODE" == install && ( -z "$DEVICE_ID" || -z "$TEAM_ID" ) ) ||
      ( -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Za-z0-9]{10}$ ) ]]; then
  echo "ERROR: Installation requires a device identifier and 10-character Apple team ID." >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$ROOT/ios/build/iphone-device"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
RUN_DIR="$OUTPUT/runs/$RUN_ID"
DERIVED="$RUN_DIR/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphoneos/MP3Shelf.app"
BUNDLE_OVERRIDE="$(printenv MP3SHELF_BUNDLE_ID 2>/dev/null || true)"
BUNDLE_ID="${BUNDLE_OVERRIDE:-com.jonnyt.mp3shelf}"
mkdir -p "$RUN_DIR"
STEP=Preflight
ACTIVE_LOG=""
BUILD_STATUS="NOT RUN"
SIGNATURE_STATUS="NOT RUN"
INSTALL_STATUS="NOT RUN"
LAUNCH_STATUS="NOT RUN"

finish() {
  local result=$?
  trap - EXIT
  set +e
  local verdict=PASS
  if [[ "$result" -ne 0 ]]; then verdict=FAIL; fi
  {
    echo "# MP3 Shelf — device build / signing report"
    echo
    echo "- Result: $verdict"
    echo "- Mode: $MODE"
    echo "- Last step: $STEP"
    echo "- Exit status: $result"
    echo "- Run: $RUN_ID"
    echo "- Source folder: $ROOT"
    echo "- Signed development build: $BUILD_STATUS"
    echo "- Signature verification: $SIGNATURE_STATUS"
    echo "- Device app installation: $INSTALL_STATUS"
    echo "- Process launch request: $LAUNCH_STATUS"
    echo "- Native audio/network/playlist acceptance: NOT TESTED"
    echo
    echo "Logs for this run: $RUN_DIR"
    if [[ "$result" -ne 0 && -n "$ACTIVE_LOG" && -f "$ACTIVE_LOG" ]]; then
      echo
      echo '## Error context'
      echo '```text'
      # Include preceding context, not only Xcode's final generic summary.
      awk '
        { ring[NR % 5] = $0 }
        /[Ee]rror:|[Cc]ode[Ss]ign|errSec|resource fork|Finder information|[Pp]rovision|[Cc]ertificate|private key|refused/ {
          for (i = NR - 4; i < NR; i++) if (i > last && i > 0 && count < 120) {
            print ring[i % 5]; last = i; count++
          }
          after = 5
        }
        after > 0 && NR > last && count < 120 { print; last = NR; count++; after-- }
      ' "$ACTIVE_LOG"
      echo
      echo '--- Final log lines ---'
      tail -n 30 "$ACTIVE_LOG"
      echo '```'
      echo
      echo "Use the specific error above to distinguish team/profile, certificate/keychain,"
      echo "or resource-fork/Finder metadata failures. The exit summary alone is insufficient."
    fi
  } > "$RUN_DIR/QA_RECORD.md"
  cp "$RUN_DIR/QA_RECORD.md" "$OUTPUT/QA_RECORD.md"
  echo
  echo "$verdict — $STEP (exit $result)"
  echo "Report: $OUTPUT/QA_RECORD.md"
  echo "Preserved run: $RUN_DIR"
  exit "$result"
}
trap finish EXIT

if [[ "$(uname -s)" != Darwin ]]; then
  echo "ERROR: A Mac with full Xcode is required." >&2; exit 2
fi
for executable in xcodebuild xcrun codesign git; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "ERROR: Missing executable: $executable" >&2; exit 2
  fi
done
DESTINATION="generic/platform=iOS"
if [[ -n "$DEVICE_ID" ]]; then
  STEP="Device connection"
  ACTIVE_LOG="$RUN_DIR/device-info.txt"
  xcrun devicectl device info details --device "$DEVICE_ID" > "$ACTIVE_LOG" 2>&1
  DESTINATION="platform=iOS,id=$DEVICE_ID"
fi
BUILD_ARGS=(-project "$ROOT/ios/MP3Shelf.xcodeproj" -scheme MP3Shelf
  -configuration Debug -sdk iphoneos -destination "$DESTINATION"
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic)
if [[ -n "$TEAM_ID" ]]; then BUILD_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID"); fi
if [[ "$MODE" == install || -n "$BUNDLE_OVERRIDE" ]]; then
  BUILD_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
fi
STEP="Build and signing"
ACTIVE_LOG="$RUN_DIR/build.log"
BUILD_STATUS=FAIL
xcodebuild "${BUILD_ARGS[@]}" build 2>&1 | tee "$ACTIVE_LOG"
BUILD_STATUS=PASS

STEP="Signature verification"
ACTIVE_LOG="$RUN_DIR/signature-check.log"
SIGNATURE_STATUS=FAIL
if [[ ! -d "$APP" || ! -f "$APP/embedded.mobileprovision" ]]; then
  echo "ERROR: Xcode did not produce a provisioned device app." | tee "$ACTIVE_LOG" >&2
  exit 4
fi
codesign --verify --deep --strict --verbose=2 "$APP" > "$ACTIVE_LOG" 2>&1
SIGNATURE_STATUS=PASS
codesign -dv --verbose=4 "$APP" > "$RUN_DIR/signature-metadata.txt" 2>&1 || true
if [[ "$MODE" == diagnose ]]; then
  STEP="Diagnostic build complete; installation not requested"
  exit 0
fi
STEP="Device installation"
ACTIVE_LOG="$RUN_DIR/install.log"
INSTALL_STATUS=FAIL
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | tee "$ACTIVE_LOG"
INSTALL_STATUS=PASS
STEP="Process launch"
ACTIVE_LOG="$RUN_DIR/launch.log"
LAUNCH_STATUS=FAIL
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | tee "$ACTIVE_LOG"
LAUNCH_STATUS=PASS
STEP="Installation and launch request complete"
