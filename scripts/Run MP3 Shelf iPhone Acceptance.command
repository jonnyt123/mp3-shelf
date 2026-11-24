#!/bin/bash
# Double-click on macOS. Isolated native worktree; real iPhone only.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This QA journey requires macOS, full Xcode and a paired physical iPhone." >&2; exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
[[ -f "$ROOT/scripts/run-iphone-playlist-acceptance.mjs" ]] || { echo "Missing native release tools" >&2; exit 2; }
for bin in xcrun node git python3 osascript xcodebuild; do
  command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 2; }
done
ORIGIN="$(git -C "$ROOT" remote get-url origin)"
case "$ORIGIN" in
  https://github.com/jonnyt123/mp3-shelf|https://github.com/jonnyt123/mp3-shelf.git|git@github.com:jonnyt123/mp3-shelf|git@github.com:jonnyt123/mp3-shelf.git) ;;
  *) echo "Unexpected GitHub origin; refusing signed device workflow." >&2; exit 2 ;;
esac
TMP="$(mktemp -d "/tmp/mp3shelf-iphone-qa.XXXXXXXX")"
WORKTREE="$TMP/candidate"
SOURCE_SHA=""
cleanup() {
  status=$?
  if [[ -n "$SOURCE_SHA" && -f "$WORKTREE/ios/build/iphone-device/QA_RECORD.md" ]]; then
    QA_DIR="$HOME/Library/Logs/MP3Shelf/DeviceAcceptance/$SOURCE_SHA/runs/$(date -u '+%Y%m%dT%H%M%SZ')-$"
    if mkdir -p "$QA_DIR" && cp -n "$WORKTREE/ios/build/iphone-device/QA_RECORD.md" "$QA_DIR/signed-install-QA_RECORD.md"; then
      chmod 600 "$QA_DIR/signed-install-QA_RECORD.md" || true
      echo "Signed build evidence preserved: $QA_DIR/signed-install-QA_RECORD.md"
    else
      echo "WARNING: signed QA evidence could not be preserved; device approval must remain blocked." >&2
    fi
  fi
  if [[ -d "$WORKTREE" ]]; then git -C "$ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT
xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null
DEVICE_ID="$(python3 - "$TMP/devices.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f: obj=json.load(f)
eligible=[]
for d in obj.get('result', {}).get('devices', []):
    props=d.get('properties', {})
    hw=props.get('hardware', d.get('hardwareProperties', {}))
    conn=props.get('connection', d.get('connectionProperties', {}))
    if (hw.get('reality') == 'physical' and hw.get('platform') == 'iOS' and
        str(hw.get('productType','')).startswith('iPhone') and
        conn.get('pairingState') == 'paired'):
        eligible.append(d.get('identifier',''))
if len(eligible) != 1:
    print('Expected exactly one paired physical iPhone; found '+str(len(eligible)),file=sys.stderr)
    sys.exit(2)
print(eligible[0])
PY
)"
if [[ ! "$DEVICE_ID" =~ ^[A-Za-z0-9-]{8,120}$ ]]; then echo "Invalid iPhone ID" >&2; exit 2; fi
echo "Paired physical iPhone detected."
TEAM="$(printenv MP3SHELF_TEAM_ID 2>/dev/null || true)"
if [[ ! "$TEAM" =~ ^[A-Za-z0-9]{10}$ ]]; then
  TEAM="$(osascript -e 'text returned of (display dialog "Enter your 10-character Apple development team ID for the signed MP3 Shelf test build:" default answer "" buttons {"Cancel", "Continue"} default button "Continue")')"
fi
[[ "$TEAM" =~ ^[A-Za-z0-9]{10}$ ]] || { echo "A valid Apple development team ID is required." >&2; exit 2; }
export MP3SHELF_TEAM_ID="$TEAM"
# Detect exactly one existing Spotify playlist. Never silently select among
# multiple playlists, and never infer a playlist from Spotify's stream URL.
PLAYLIST="$(printenv MP3SHELF_PLAYLIST_UUID 2>/dev/null || true)"
if [[ -z "$PLAYLIST" ]]; then
  if xcrun devicectl device copy from --device "$DEVICE_ID" \
       --domain-type appDataContainer --domain-identifier com.jonnyt.mp3shelf \
       --source "Library/Application Support/MP3Shelf/library.json" \
       --destination "$TMP/library.json" >/dev/null 2>&1; then
    PLAYLIST="$(node "$ROOT/scripts/choose-iphone-playlist.mjs" "$TMP/library.json")"
  fi
fi
if [[ -z "$PLAYLIST" ]]; then
  echo "No saved Spotify playlist was accessible on the paired iPhone. Import a playlist in MP3 Shelf while connected, unlock the device and retry." >&2
  exit 2
fi
if [[ ! "$PLAYLIST" =~ ^[A-Fa-f0-9]{8}-([A-Fa-f0-9]{4}-){3}[A-Fa-f0-9]{12}$ ]]; then
  echo "A local Spotify playlist UUID is required." >&2; exit 2
fi
echo "Preparing an isolated exact-GitHub-source build…"
git -C "$ROOT" fetch --no-tags origin refs/heads/agent/mp3-native-integration-preflight
SOURCE_SHA="$(git -C "$ROOT" ls-remote --exit-code origin refs/heads/agent/mp3-native-integration-preflight | awk '{print $1}')"
[[ "$SOURCE_SHA" =~ ^[a-f0-9]{40}$ ]] || { echo "Invalid preflight Git SHA" >&2; exit 2; }
git -C "$ROOT" cat-file -e "$SOURCE_SHA^{commit}" || {
  echo "The preflight branch advanced during fetch. Retry the exact current SHA." >&2; exit 2;
}
git -C "$ROOT" worktree add --detach "$WORKTREE" "$SOURCE_SHA"
echo "Building, installing and verifying candidate $SOURCE_SHA."
echo "Airplane Mode with Wi-Fi off is the only physical network action required when prompted."
node "$ROOT/scripts/run-iphone-playlist-acceptance.mjs" "$DEVICE_ID" "$PLAYLIST" "$SOURCE_SHA" "$WORKTREE"
echo "Reviewing collected iPhone audio hashes and signed-build evidence. This is not hardware approval."
DEVICE_INVENTORY="$HOME/Library/Logs/MP3Shelf/DeviceAcceptance/$SOURCE_SHA/physical-inventory.json"
SIGNED_QA="$WORKTREE/ios/build/iphone-device/QA_RECORD.md"
REVIEW_RESULT="$(node "$ROOT/scripts/review-iphone-evidence.mjs" "$DEVICE_INVENTORY" "$SIGNED_QA" "$SOURCE_SHA")"
echo "$REVIEW_RESULT"
REVIEW_PATH="$(printf '%s' "$REVIEW_RESULT" | node -e 'let s="";process.stdin.setEncoding("utf8");process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const j=JSON.parse(s);if(typeof j.path!=="string"||!j.path.endsWith(".json"))process.exit(1);console.log(j.path)})')"
node "$ROOT/scripts/stage-iphone-review.mjs" "$DEVICE_INVENTORY" "$REVIEW_PATH" "$SIGNED_QA" "$SOURCE_SHA"
echo "Evidence staged for the release gate. No hardware approval was issued; owner review in GitHub issue #6 remains mandatory."
