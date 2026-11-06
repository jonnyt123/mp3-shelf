#!/usr/bin/env bash
# Local Simulator test only. Never signs, uploads, or clears the normal app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OUT="$ROOT/ios/build/download-proof"
RUN_OUT="$OUT/runs/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
BUNDLE=com.jonnyt.mp3shelf.downloadproof
SIMULATOR=""
STEP=preflight
mkdir -p "$RUN_OUT"
on_exit() {
  local result=$?
  {
    echo '# MP3 Shelf live download proof'
    echo
    echo "- Result: $([[ $result -eq 0 ]] && echo PASS || echo FAIL)"
    echo "- Exit status: $result"
    echo "- Last step: $STEP"
    echo "- Run output: $RUN_OUT"
    echo '- Scope: isolated iOS Simulator app, foreground download/import/playback.'
    echo '- Selection mode is recorded in native-result.json; reference-review does not prove automatic selection.'
    echo '- Physical-iPhone/background acceptance: NOT TESTED'
    echo '- Signing / GitHub Actions: NOT USED'
    if [[ $result -ne 0 && -f "$RUN_OUT/$STEP.log" ]]; then
      echo
      echo '```text'
      tail -n 30 "$RUN_OUT/$STEP.log"
      echo '```'
    fi
    if [[ $result -ne 0 && -f "$RUN_OUT/native-result.json" ]]; then
      echo
      python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error","Native proof failed"))' "$RUN_OUT/native-result.json"
    fi
  } > "$RUN_OUT/QA_RECORD.md"
  cp "$RUN_OUT/QA_RECORD.md" "$OUT/QA_RECORD.md"
  if [[ -n "$SIMULATOR" ]]; then xcrun simctl terminate "$SIMULATOR" "$BUNDLE" >/dev/null 2>&1 || true; fi
}
trap on_exit EXIT
[[ "$(uname -s)" == Darwin ]] || { echo 'ERROR: This live test requires macOS with Xcode.' >&2; exit 2; }
for tool in xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: Missing $tool." >&2; exit 2; }
done
TIMEOUT="${MP3SHELF_PROOF_TIMEOUT:-600}"
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -ge 1 && "$TIMEOUT" -le 1800 ]] || {
  echo 'ERROR: MP3SHELF_PROOF_TIMEOUT must be 1–1800 seconds.' >&2; exit 2;
}
run_step() {
  STEP="$1"; shift
  echo "Running $STEP…"
  "$@" > "$RUN_OUT/$STEP.log" 2>&1
}
run_step build xcodebuild -project "$ROOT/ios/MP3Shelf.xcodeproj" -scheme MP3Shelf \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$RUN_OUT/DerivedData" CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build
APP="$RUN_OUT/DerivedData/Build/Products/Debug-iphonesimulator/MP3Shelf.app"
STEP=verify-isolated-bundle
python3 - "$APP/Info.plist" "$BUNDLE" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file: info = plistlib.load(file)
if info.get('CFBundleIdentifier') != sys.argv[2]:
    raise SystemExit('ERROR: Refusing to use a non-isolated app identifier.')
PY
STEP=select-simulator
SIMULATOR="$(xcrun simctl list -j devices available | python3 -c '
import json,sys
devices=[d for group in json.load(sys.stdin)["devices"].values() for d in group
         if d.get("isAvailable",False) and "iPhone" in d.get("name","")]
devices.sort(key=lambda d:d.get("state") != "Booted")
if not devices: raise SystemExit("No available iPhone Simulator runtime")
print(devices[0]["udid"])
')"
xcrun simctl boot "$SIMULATOR" > "$RUN_OUT/boot.log" 2>&1 || true
run_step boot-ready xcrun simctl bootstatus "$SIMULATOR" -b
# Only the dedicated test app is reset. Existing MP3 Shelf data stays intact.
xcrun simctl uninstall "$SIMULATOR" "$BUNDLE" > "$RUN_OUT/reset.log" 2>&1 || true
run_step install xcrun simctl install "$SIMULATOR" "$APP"
CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR" "$BUNDLE" data)"
run_step launch xcrun simctl launch "$SIMULATOR" "$BUNDLE" --mp3shelf-prove-download
STEP=wait-for-native-proof
REPORT="$CONTAINER/Documents/MP3ShelfDownloadProof.json"
DEADLINE=$((SECONDS + TIMEOUT))
LAST_STAGE=""
while [[ "$SECONDS" -lt "$DEADLINE" ]]; do
  if [[ -f "$REPORT" ]]; then
    STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","UNKNOWN"))' "$REPORT")"
    STAGE="$(python3 -c 'import json,sys; steps=json.load(open(sys.argv[1])).get("steps",[]); print(steps[-1].get("stage","") if steps else "")' "$REPORT")"
    if [[ "$STAGE" != "$LAST_STAGE" ]]; then echo "Native stage: $STAGE"; LAST_STAGE="$STAGE"; fi
    if [[ "$STATUS" == PASS || "$STATUS" == FAIL ]]; then
      cp "$REPORT" "$RUN_OUT/native-result.json"
      STEP=validate-native-proof
      python3 "$ROOT/ios/scripts/validate-download-proof.py" "$REPORT" "$CONTAINER" "$RUN_OUT"
      STEP=complete
      echo "Native download proof passed. Results and MP3: $RUN_OUT"
      exit 0
    fi
  fi
  sleep 1
done
echo 'ERROR: Native proof did not finish; no PASS is claimed.' >&2
exit 1
