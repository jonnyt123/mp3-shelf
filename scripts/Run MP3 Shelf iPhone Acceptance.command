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
    QA_DIR="$HOME/Library/Logs/MP3Shelf/DeviceAcceptance/$SOURCE_SHA"
    mkdir -p "$QA_DIR"
    cp "$WORKTREE/ios/build/iphone-device/QA_RECORD.md" "$QA_DIR/signed-install-QA_RECORD.md"
    chmod 600 "$QA_DIR/signed-install-QA_RECORD.md"
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
    PLAYLIST="$(python3 - "$TMP/library.json" <<'PY'
import json, re, sys
from urllib.parse import urlsplit
try:
    with open(sys.argv[1], encoding='utf-8') as f: obj=json.load(f)
    matches=[]
    for p in obj.get('playlists',[]):
        parsed=urlsplit(p.get('sourceURL',''))
        if (parsed.scheme=='https' and parsed.hostname=='open.spotify.com'
            and not parsed.username and not parsed.password and not parsed.fragment
            and re.fullmatch(r'/playlist/[A-Za-z0-9]{22}/?', parsed.path)
            and p.get('trackIDs')):
            matches.append(p.get('id',''))
    if len(matches) == 1: print(matches[0])
except (OSError,ValueError,TypeError): pass
PY
)"
  fi
fi
if [[ -z "$PLAYLIST" ]]; then
  PLAYLIST="$(osascript -e 'text returned of (display dialog "Enter the local Spotify playlist UUID in MP3 Shelf to test offline:" default answer "" buttons {"Cancel", "Continue"} default button "Continue")')"
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
echo "Read-only physical QA finished. Issue #6 still requires independent hardware review."
