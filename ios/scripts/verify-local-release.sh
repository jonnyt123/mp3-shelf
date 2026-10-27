#!/usr/bin/env bash
# Runs the native release gates on the developer's Mac, never on GitHub Actions.
# Nothing here signs an app, uploads artifacts, or alters production.
set -euo pipefail

usage() {
  cat <<'HELP'
MP3 Shelf — local native verification without GitHub Actions

  bash ios/scripts/verify-local-release.sh
  bash ios/scripts/verify-local-release.sh --tests-only
  bash ios/scripts/verify-local-release.sh --builds-only
  bash ios/scripts/verify-local-release.sh --smoke

Default: all five Swift regression suites plus unsigned simulator Debug,
simulator Release and physical-iPhone arm64 Release builds.
--tests-only: run the Foundation-based Swift regression suites (no Xcode build).
--builds-only: compile all three native configurations, skip Swift suites.
--smoke: run the default checks, then launch the Debug app on a local
         iPhone Simulator and capture eight UI snapshots. Requires installed
         compatible simulator runtime; does not substitute for iPhone QA.

Local outputs and logs: ios/build/local-release/ (Git-ignored).
Requires full Xcode on macOS for builds/smoke. No signing or CI minutes.
HELP
}

MODE=all
SMOKE=false
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --tests-only) MODE=tests ;;
    --builds-only) MODE=builds ;;
    --smoke) SMOKE=true ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "$SMOKE" == true && "$MODE" != all ]]; then
  echo "ERROR: --smoke must include the Debug simulator build." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/ios/build/local-release"
DERIVED="$OUT/DerivedData"
mkdir -p "$OUT"
cd "$ROOT"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "ERROR: Swift compiler not found." >&2
  exit 2
fi
if [[ "$MODE" != tests ]]; then
  if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "ERROR: Native builds require macOS with full Xcode selected." >&2
    exit 2
  fi
  if ! xcodebuild -version > "$OUT/xcode-version.txt" 2>&1; then
    echo "ERROR: Select full Xcode using xcode-select, not Command Line Tools." >&2
    exit 2
  fi
fi

COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY=no
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
  DIRTY=yes
fi
STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
COMPLETED_STEPS=()
on_exit() {
  local status=$?
  {
    echo "# MP3 Shelf — local native verification evidence"
    echo
    echo "- Started (UTC): $STARTED"
    echo "- Checked commit: $COMMIT"
    echo "- Uncommitted changes: $DIRTY"
    echo "- Mode: $MODE"
    echo "- Simulator smoke requested: $SMOKE"
    echo "- Overall execution: $([[ $status -eq 0 ]] && echo PASS || echo FAIL)"
    echo "- Completed checks: ${COMPLETED_STEPS[*]:-none}"
    echo "- Apple signing / physical iPhone acceptance: NOT TESTED"
    echo "- GitHub Actions used: NO"
    echo
    echo "Build logs, Swift test results and optional screenshots are local to this directory."
    echo "A PASS does not establish real-device playback, permissions or background scheduling."
  } > "$OUT/QA_RECORD.md"
  if [[ $status -ne 0 ]]; then
    echo "Local verification failed. See $OUT/QA_RECORD.md and step logs." >&2
  fi
}
trap on_exit EXIT

run_step() {
  local name="$1"; shift
  echo "==> $name"
  "$@" 2>&1 | tee "$OUT/$name.log"
  COMPLETED_STEPS+=("$name")
}
run_suite() {
  local name="$1"; shift
  echo "==> Compiling $name"
  swiftc "$@" -o "$OUT/$name" 2>&1 | tee "$OUT/$name-compile.log"
  run_step "$name" "$OUT/$name"
}

if [[ "$MODE" != builds ]]; then
  run_suite playlist-parser \
    ios/MP3Shelf/Models/MusicModels.swift \
    ios/MP3Shelf/Services/PlaylistCSV.swift \
    ios/Tests/PlaylistCSVTests.swift
  run_suite lyrics-parser \
    ios/MP3Shelf/Services/LyricsParser.swift \
    ios/Tests/LyricsParserTests.swift
  run_suite authorized-audio-sources \
    ios/MP3Shelf/Models/MusicModels.swift \
    ios/MP3Shelf/Services/PlaylistCSV.swift \
    ios/MP3Shelf/Services/AudioSourceFinder.swift \
    ios/Tests/AudioSourceFinderTests.swift
  run_suite discovery-resume \
    ios/MP3Shelf/Models/MusicModels.swift \
    ios/MP3Shelf/Models/SourceDiscoveryJob.swift \
    ios/Tests/SourceDiscoveryJobTests.swift
  run_suite portable-backup \
    ios/MP3Shelf/Models/MusicModels.swift \
    ios/MP3Shelf/Services/PortableShelfArchive.swift \
    ios/Tests/PortableShelfArchiveTests.swift
fi

if [[ "$MODE" != tests ]]; then
  PROJECT="$ROOT/ios/MP3Shelf.xcodeproj"
  COMMON=(
    -project "$PROJECT" -scheme MP3Shelf
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO
  )
  run_step simulator-debug xcodebuild "${COMMON[@]}" \
    -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' build
  run_step simulator-release xcodebuild "${COMMON[@]}" \
    -configuration Release -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' build
  run_step iphoneos-arm64-release xcodebuild "${COMMON[@]}" \
    -configuration Release -sdk iphoneos \
    -destination 'generic/platform=iOS' build
fi

if [[ "$SMOKE" == true ]]; then
  for executable in xcrun python3; do
    command -v "$executable" >/dev/null || {
      echo "ERROR: missing $executable for simulator smoke test." >&2
      exit 3
    }
  done
  SIMULATOR="$(xcrun simctl list -j devices available | python3 -c '
import json, sys
data=json.load(sys.stdin)
for devices in data.get("devices", {}).values():
    for device in devices:
        if "iPhone" in device.get("name","") and device.get("isAvailable",False):
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
')"
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/MP3Shelf.app"
  if [[ -z "$SIMULATOR" || ! -d "$APP" ]]; then
    echo "ERROR: iPhone Simulator/runtime or Debug .app unavailable." >&2
    exit 3
  fi
  xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
  run_step simulator-boot xcrun simctl bootstatus "$SIMULATOR" -b
  run_step simulator-install xcrun simctl install "$SIMULATOR" "$APP"
  mkdir -p "$OUT/screenshots"
  for tab in listen playlists add-music settings downloads filled-library search player; do
    if [[ "$tab" == listen ]]; then
      run_step "launch-$tab" xcrun simctl launch "$SIMULATOR" com.jonnyt.mp3shelf
    else
      run_step "launch-$tab" xcrun simctl launch "$SIMULATOR" \
        com.jonnyt.mp3shelf "--mp3shelf-snapshot-$tab"
    fi
    case "$tab" in
      player|search|filled-library) sleep 7 ;;
      *) sleep 3 ;;
    esac
    run_step "snapshot-$tab" xcrun simctl io "$SIMULATOR" screenshot \
      "$OUT/screenshots/$tab.png"
    xcrun simctl terminate "$SIMULATOR" com.jonnyt.mp3shelf || true
  done
  echo "Screenshots captured; visual/accessibility review is still required."
fi

echo "Local checks finished; report: $OUT/QA_RECORD.md"
