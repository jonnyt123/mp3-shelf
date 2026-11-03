#!/usr/bin/env bash
# Pull-driven, tokenless Mac QA. Does not open inbound ports or consume GitHub Actions.
set -euo pipefail
ROOT="$HOME/Library/Application Support/MP3ShelfCloudQA"
REPO="$ROOT/repository"
mkdir -p "$ROOT/logs" "$ROOT/reports"
if ! mkdir "$ROOT/run.lock" 2>/dev/null; then echo "QA already running"; exit 0; fi
trap 'rmdir "$ROOT/run.lock"' EXIT
command -v xcodebuild >/dev/null
command -v swiftc >/dev/null
[[ -d "$REPO/.git" ]] || git clone --no-checkout https://github.com/jonnyt123/mp3-shelf.git "$REPO"
[[ "$(git -C "$REPO" remote get-url origin)" == "https://github.com/jonnyt123/mp3-shelf.git" ]] || exit 1
for role in mp3-playback mp3-sources mp3-ui mp3-qa mp3-integration; do
  branch="agent/$role"
  line=$(git -C "$REPO" ls-remote --heads origin "refs/heads/$branch")
  [[ -n "$line" ]] || continue
  sha=$(printf '%s' "$line" | cut -f1)
  [[ "$sha" =~ ^[a-f0-9]{40}$ ]] || continue
  report="$ROOT/reports/$role.json"
  if [[ -f "$report" ]] && /usr/bin/python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); sys.exit(0 if a.get("sha")==sys.argv[2] else 1)' "$report" "$sha"; then continue; fi
  log="$ROOT/logs/$role-$sha.log"
  git -C "$REPO" fetch --no-tags origin "refs/heads/$branch"
  [[ "$(git -C "$REPO" rev-parse FETCH_HEAD)" == "$sha" ]] || { echo "Branch advanced during fetch; retry next cycle"; continue; }
  git -C "$REPO" checkout --detach --force "$sha"
  result=success
  (
    cd "$REPO"
    bash -n ios/scripts/run-on-iphone.sh
    xcodebuild -project ios/MP3Shelf.xcodeproj -scheme MP3Shelf -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
    mkdir -p "$ROOT/bin"
    swiftc ios/MP3Shelf/Models/MusicModels.swift ios/MP3Shelf/Services/PlaylistCSV.swift ios/Tests/PlaylistCSVTests.swift -o "$ROOT/bin/playlist" && "$ROOT/bin/playlist"
    swiftc ios/MP3Shelf/Services/LyricsParser.swift ios/Tests/LyricsParserTests.swift -o "$ROOT/bin/lyrics" && "$ROOT/bin/lyrics"
    swiftc ios/MP3Shelf/Models/MusicModels.swift ios/MP3Shelf/Services/PlaylistCSV.swift ios/MP3Shelf/Services/AudioSourceFinder.swift ios/Tests/AudioSourceFinderTests.swift -o "$ROOT/bin/source" && "$ROOT/bin/source"
    swiftc ios/MP3Shelf/Models/MusicModels.swift ios/MP3Shelf/Models/SourceDiscoveryJob.swift ios/Tests/SourceDiscoveryJobTests.swift -o "$ROOT/bin/discovery" && "$ROOT/bin/discovery"
    swiftc ios/MP3Shelf/Models/MusicModels.swift ios/MP3Shelf/Services/PortableShelfArchive.swift ios/Tests/PortableShelfArchiveTests.swift -o "$ROOT/bin/archive" && "$ROOT/bin/archive"
  ) >"$log" 2>&1 || result=failure
  /usr/bin/python3 - "$report" "$role" "$sha" "$result" "$log" <<'PY'
import datetime,json,os,sys
dst,role,sha,result,log=sys.argv[1:]
data={"role":role,"sha":sha,"status":result,"check":"unsigned-simulator-build-and-Swift-regressions","physical_iphone":"NOT_TESTED","log":log,"time":datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(dst+".tmp","w") as f: json.dump(data,f)
os.replace(dst+".tmp",dst)
PY
  echo "$role $result at $sha (log: $log)"
done
