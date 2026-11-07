#!/usr/bin/env bash
# Local Simulator test only. Never signs, uploads, or clears the normal app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OUT="$ROOT/ios/build/download-proof"
MODE=live-download
FIRST_ARGUMENT=--mp3shelf-prove-download
if [[ $# -eq 1 && "$1" == --offline-restart ]]; then
  MODE=local-import-restart
  OUT="$ROOT/ios/build/offline-restart-proof"
  FIRST_ARGUMENT=--mp3shelf-prove-local-restart
elif [[ $# -eq 1 && "$1" == --fixture-transfer ]]; then
  MODE=fixture-transfer
  OUT="$ROOT/ios/build/fixture-transfer-proof"
  FIRST_ARGUMENT=--mp3shelf-prove-fixture-transfer
elif [[ $# -ne 0 ]]; then
  echo 'Usage: prove-download-path.sh [--offline-restart | --fixture-transfer]' >&2
  exit 2
fi
RUN_OUT="$OUT/runs/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
BUNDLE=com.jonnyt.mp3shelf.downloadproof
SIMULATOR=""
OWNS_SIMULATOR=false
FIXTURE_PID=""
STEP=preflight
mkdir -p "$RUN_OUT"
stop_fixture() {
  if [[ -n "$FIXTURE_PID" ]]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
    FIXTURE_PID=""
  fi
}
on_exit() {
  local result="$1"
  if [[ "${BASH_SUBSHELL:-0}" -ne 0 ]]; then return "$result"; fi
  trap - EXIT
  local summary=""
  if [[ $result -eq 0 && "$STEP" != complete ]]; then
    result=1
    summary="The launcher exited before validating the native receipt."
    printf 'ERROR: %s Last step was %s.\n' "$summary" "$STEP" >&2
  fi
  stop_fixture
  {
    echo "# MP3 Shelf $MODE proof"
    echo
    echo "- Result: $([[ $result -eq 0 ]] && echo PASS || echo FAIL)"
    echo "- Exit status: $result"
    echo "- Last step: $STEP"
    if [[ -n "$summary" ]]; then echo "- Detail: $summary"; fi
    echo "- Shell: Bash $BASH_VERSION"
    echo "- Proof mode: $MODE"
    echo "- Run output: $RUN_OUT"
    echo '- Scope: isolated Simulator app, persisted MP3 import and playback in a fresh process.'
    if [[ "$MODE" == local-import-restart ]]; then
      echo '- This fixture-only result does NOT establish live song search or download success.'
    elif [[ "$MODE" == fixture-transfer ]]; then
      echo '- Input: bundled AAC sent over loopback through the background transfer queue.'
      echo '- Live song matching and provider availability are covered by the separate live download proof.'
    fi
    echo '- Restart phase: foreground HTTP refused; source discovery and transfer attachment disabled.'
    echo '- Device Airplane Mode / host connectivity changes: NOT TESTED / NOT USED'
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
  if [[ "$OWNS_SIMULATOR" == true ]]; then xcrun simctl terminate "$SIMULATOR" "$BUNDLE" >/dev/null 2>&1 || true; fi
  exit "$result"
}
trap 'on_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
preflight_error() {
  printf 'ERROR: %s\n' "$1" > "$RUN_OUT/preflight.log"
  cat "$RUN_OUT/preflight.log" >&2
  exit 2
}
[[ "$(uname -s)" == Darwin ]] || preflight_error 'This native test requires macOS with Xcode.'
for tool in xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null || preflight_error "Missing $tool."
done
TIMEOUT="${MP3SHELF_PROOF_TIMEOUT:-600}"
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -ge 1 && "$TIMEOUT" -le 1800 ]] || {
  preflight_error 'MP3SHELF_PROOF_TIMEOUT must be 1–1800 seconds.'
}
RUN_TOKEN="$(python3 -c 'import uuid; print(uuid.uuid4())')"
run_step() {
  STEP="$1"; shift
  echo "Running $STEP…"
  "$@" > "$RUN_OUT/$STEP.log" 2>&1
}
BUILD_SETTINGS=(CODE_SIGNING_ALLOWED=NO "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE")
if [[ "$MODE" == fixture-transfer ]]; then
  run_step configure-fixture-bundle python3 -c '
import plistlib, sys
with open(sys.argv[1], "rb") as file: info = plistlib.load(file)
domains = info.setdefault("NSAppTransportSecurity", {}).setdefault("NSExceptionDomains", {})
domains["127.0.0.1"] = {"NSExceptionAllowsInsecureHTTPLoads": True}
with open(sys.argv[2], "wb") as file: plistlib.dump(info, file)
' "$ROOT/ios/MP3Shelf/Resources/Info.plist" "$RUN_OUT/FixtureInfo.plist"
  BUILD_SETTINGS=("${BUILD_SETTINGS[@]}" "INFOPLIST_FILE=$RUN_OUT/FixtureInfo.plist")
fi
run_step build xcodebuild -project "$ROOT/ios/MP3Shelf.xcodeproj" -scheme MP3Shelf \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$RUN_OUT/DerivedData" "${BUILD_SETTINGS[@]}" build
APP="$RUN_OUT/DerivedData/Build/Products/Debug-iphonesimulator/MP3Shelf.app"
STEP=verify-isolated-bundle
python3 - "$APP/Info.plist" "$BUNDLE" "$MODE" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file: info = plistlib.load(file)
if info.get('CFBundleIdentifier') != sys.argv[2]:
    raise SystemExit('ERROR: Refusing to use a non-isolated app identifier.')
if sys.argv[3] == 'fixture-transfer':
    ats = info.get('NSAppTransportSecurity', {})
    if ats != {'NSExceptionDomains': {'127.0.0.1': {'NSExceptionAllowsInsecureHTTPLoads': True}}}:
        raise SystemExit('ERROR: The isolated app needs only the loopback ATS exception.')
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
# Hold the lock on the inherited descriptor until this runner exits. Other
# proof modes use the same isolated bundle on the selected Simulator.
exec 9>"${TMPDIR:-/tmp}/mp3shelf-download-proof-$SIMULATOR.lock"
run_step lock-simulator python3 -c '
import fcntl
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit("Another MP3 Shelf proof is using this Simulator.")
'
OWNS_SIMULATOR=true
xcrun simctl boot "$SIMULATOR" > "$RUN_OUT/boot.log" 2>&1 || true
run_step boot-ready xcrun simctl bootstatus "$SIMULATOR" -b
# Only the dedicated test app is reset. Existing MP3 Shelf data stays intact.
xcrun simctl uninstall "$SIMULATOR" "$BUNDLE" > "$RUN_OUT/reset.log" 2>&1 || true
run_step install xcrun simctl install "$SIMULATOR" "$APP"
CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR" "$BUNDLE" data)"
FIRST_LAUNCH=("$FIRST_ARGUMENT" --mp3shelf-proof-run "$RUN_TOKEN")
if [[ "$MODE" == local-import-restart ]]; then
  mkdir -p "$CONTAINER/Documents"
  run_step stage-local-fixture cp "$ROOT/ios/Tests/Fixtures/valid-mp3.mp3" "$CONTAINER/Documents/MP3ShelfRestartFixture.mp3"
elif [[ "$MODE" == fixture-transfer ]]; then
  STEP=serve-fixture
  python3 "$ROOT/ios/scripts/serve-download-fixture.py" \
    "$ROOT/ios/Tests/Fixtures/transfer-tone.m4a" "$RUN_OUT" "$RUN_TOKEN" \
    > "$RUN_OUT/$STEP.log" 2>&1 9>&- &
  FIXTURE_PID=$!
  for attempt in {1..50}; do
    [[ -s "$RUN_OUT/fixture-port" ]] && break
    kill -0 "$FIXTURE_PID" 2>/dev/null || break
    sleep 0.1
  done
  if [[ ! -s "$RUN_OUT/fixture-port" ]]; then
    echo 'ERROR: The local AAC fixture server did not start.' >&2
    exit 1
  fi
  FIRST_LAUNCH=("${FIRST_LAUNCH[@]}" --mp3shelf-proof-fixture-port "$(cat "$RUN_OUT/fixture-port")")
fi
run_step launch xcrun simctl launch "$SIMULATOR" "$BUNDLE" "${FIRST_LAUNCH[@]}"
STEP=wait-for-native-proof
REPORT="$CONTAINER/Documents/MP3ShelfDownloadProof.json"
DEADLINE=$((SECONDS + TIMEOUT))
LAST_STAGE=""
RESTARTED=false
while [[ "$SECONDS" -lt "$DEADLINE" ]]; do
  if [[ -f "$REPORT" ]]; then
    REPORT_RUN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("runID",""))' "$REPORT")"
    if [[ "$REPORT_RUN" != "$RUN_TOKEN" ]]; then sleep 1; continue; fi
    STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","UNKNOWN"))' "$REPORT")"
    STAGE="$(python3 -c 'import json,sys; steps=json.load(open(sys.argv[1])).get("steps",[]); print(steps[-1].get("stage","") if steps else "")' "$REPORT")"
    if [[ "$STAGE" != "$LAST_STAGE" ]]; then echo "Native stage: $STAGE"; LAST_STAGE="$STAGE"; fi
    if [[ "$STATUS" == READY_FOR_RESTART && "$RESTARTED" == false ]]; then
      cp "$REPORT" "$RUN_OUT/pre-restart-result.json"
      run_step restart-stop xcrun simctl terminate "$SIMULATOR" "$BUNDLE"
      stop_fixture
      run_step restart-launch xcrun simctl launch "$SIMULATOR" "$BUNDLE" --mp3shelf-prove-offline-restart --mp3shelf-proof-run "$RUN_TOKEN"
      RESTARTED=true
      STEP=wait-for-restart-proof
      continue
    fi
    if [[ "$STATUS" == PASS || "$STATUS" == FAIL ]]; then
      STEP=validate-native-proof
      cp "$REPORT" "$RUN_OUT/native-result.json"
      if [[ "$STATUS" == PASS && "$RESTARTED" != true ]]; then
        echo 'ERROR: A fresh-process restart is required before PASS.' >&2
        exit 1
      fi
      if ! run_step validate-native-proof python3 "$ROOT/ios/scripts/validate-download-proof.py" \
        "$RUN_OUT/native-result.json" "$CONTAINER" "$RUN_OUT" "$RUN_TOKEN" "$MODE"; then
        cat "$RUN_OUT/validate-native-proof.log" >&2
        exit 1
      fi
      STEP=complete
      echo "Native $MODE proof passed. Results and MP3: $RUN_OUT"
      exit 0
    fi
  fi
  sleep 1
done
echo 'ERROR: Native proof did not finish; no PASS is claimed.' >&2
exit 1
