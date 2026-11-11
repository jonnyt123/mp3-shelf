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

Default: all nine Swift regression suites, the C matching core, unsigned simulator Debug,
simulator Release and physical-iPhone arm64 Release builds.
--tests-only: run Swift regressions (codec tests require macOS AVFoundation).
--builds-only: compile all three native configurations, skip Swift suites.
--smoke: run the default checks, then launch the Debug app on a local
         iPhone Simulator and capture eight UI snapshots. Requires installed
         compatible simulator runtime; does not substitute for iPhone QA.

Latest report: ios/build/local-release/QA_RECORD.md (Git-ignored).
Each invocation keeps its logs under ios/build/local-release/runs/.
Requires full Xcode on macOS for builds/smoke. No signing or CI minutes.
HELP
}

MODE=all
SMOKE=false
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --tests-only)
      if [[ "$MODE" == builds ]]; then echo "ERROR: Choose either --tests-only or --builds-only." >&2; exit 2; fi
      MODE=tests ;;
    --builds-only)
      if [[ "$MODE" == tests ]]; then echo "ERROR: Choose either --tests-only or --builds-only." >&2; exit 2; fi
      MODE=builds ;;
    --smoke) SMOKE=true ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "$SMOKE" == true && "$MODE" != all ]]; then
  echo "ERROR: --smoke must include the Debug simulator build." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OUT="$ROOT/ios/build/local-release"
DERIVED="$OUT/DerivedData"
mkdir -p "$OUT"
cd "$ROOT"


COMMIT=unknown
DIRTY=unknown
SOURCE_PROVENANCE="unidentified source"
GIT_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ "$GIT_TOP" == "$ROOT" ]]; then
  COMMIT="$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)"
  DIRTY=no
  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then DIRTY=yes; fi
  SOURCE_PROVENANCE="repository HEAD"
  if [[ "$COMMIT" == unknown ]]; then SOURCE_PROVENANCE="repository without a commit"; fi
elif [[ -f "$ROOT/SOURCE.json" ]] && command -v python3 >/dev/null 2>&1; then
  COMMIT="$(python3 - "$ROOT/SOURCE.json" <<'PY_SOURCE'
import json, re, sys
try:
    value = json.load(open(sys.argv[1])).get("commit", "")
    print(value if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{40}", value) else "unknown")
except (OSError, ValueError, AttributeError):
    print("unknown")
PY_SOURCE
)"
  SOURCE_PROVENANCE="archive metadata (not independently authenticated)"
fi
STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
RUN_OUT="$OUT/runs/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -p "$RUN_OUT"
COMPLETED_STEPS=()
FAILURE_REASON=""
on_exit() {
  local status=$?
  {
    echo "# MP3 Shelf — local native verification evidence"
    echo
    echo "- Started (UTC): $STARTED"
    echo "- Checked commit: $COMMIT"
    echo "- Source provenance: $SOURCE_PROVENANCE"
    echo "- Current run logs: $RUN_OUT"
    echo "- Uncommitted changes: $DIRTY"
    echo "- Mode: $MODE"
    echo "- Simulator smoke requested: $SMOKE"
    echo "- Overall execution: $([[ $status -eq 0 ]] && echo PASS || echo FAIL)"
    echo "- Exit status: $status"
    echo "- Failure reason: ${FAILURE_REASON:-none}"
    echo "- Completed checks: ${COMPLETED_STEPS[*]:-none}"
    echo "- Apple signing / physical iPhone acceptance: NOT TESTED"
    echo "- GitHub Actions used: NO"
    echo
    echo "Build logs, Swift test results and optional screenshots are local to this directory."
    echo "A PASS does not establish real-device playback, permissions or background scheduling."
  } > "$RUN_OUT/QA_RECORD.md"
  cp "$RUN_OUT/QA_RECORD.md" "$OUT/QA_RECORD.md"
  if [[ $status -ne 0 ]]; then
    echo "Local verification failed. See $OUT/QA_RECORD.md and step logs." >&2
  fi
}
trap on_exit EXIT

if [[ "$MODE" != builds ]] && ! command -v swiftc >/dev/null 2>&1; then
  FAILURE_REASON="Swift compiler not found"
  echo "ERROR: $FAILURE_REASON." >&2
  exit 2
fi
if [[ "$MODE" != tests ]]; then
  if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
    FAILURE_REASON="Native builds require macOS with full Xcode selected"
    echo "ERROR: $FAILURE_REASON." >&2
    exit 2
  fi
  if ! xcodebuild -version > "$RUN_OUT/xcode-version.txt" 2>&1; then
    FAILURE_REASON="Full Xcode is not selected or cannot run"
    echo "ERROR: $FAILURE_REASON." >&2
    exit 2
  fi
fi


run_step() {
  local name="$1"; shift
  echo "==> $name"
  FAILURE_REASON="Step $name failed (see $RUN_OUT/$name.log)"
  "$@" 2>&1 | tee "$RUN_OUT/$name.log"
  COMPLETED_STEPS+=("$name")
  FAILURE_REASON=""
}
run_suite() {
  local name="$1"; shift
  echo "==> Compiling $name"
  FAILURE_REASON="Compile $name failed (see $RUN_OUT/$name-compile.log)"
  swiftc "$@" -o "$RUN_OUT/$name" 2>&1 | tee "$RUN_OUT/$name-compile.log"
  run_step "$name" "$RUN_OUT/$name"
}

if [[ "$MODE" != builds ]]; then
  run_suite playback-order \
    ios/MP3Shelf/Models/PlaybackOrder.swift \
    ios/Tests/PlaybackOrderTests.swift
  run_suite playback-interruptions \
    ios/MP3Shelf/Models/MusicModels.swift \
    ios/Tests/PlaybackInterruptionTests.swift
  run_suite downloaded-audio-signature \
    ios/MP3Shelf/Models/DownloadedAudioSignature.swift \
    ios/Tests/DownloadedAudioSignatureTests.swift
  run_suite downloaded-audio-format \
    ios/MP3Shelf/Models/MusicModels.swift \
    ios/Tests/DownloadedAudioFormatTests.swift
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
  run_step recording-matching-core /bin/bash "$ROOT/ios/scripts/test-recording-matcher-core.sh" "$RUN_OUT"
  run_suite recording-matcher \
    -I "$ROOT/ios/Packages/ShelfMatching/Sources/ShelfMatching/include" \
    ios/MP3Shelf/Models/MusicModels.swift \
    ios/MP3Shelf/Services/PlaylistCSV.swift \
    ios/MP3Shelf/Services/RecordingMatcher.swift \
    ios/Tests/RecordingMatcherTests.swift \
    "$RUN_OUT/ShelfMatching.o"
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
  FAILURE_REASON="No available iPhone Simulator could be selected"
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
  FAILURE_REASON=""
  xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
  run_step simulator-boot xcrun simctl bootstatus "$SIMULATOR" -b
  run_step simulator-install xcrun simctl install "$SIMULATOR" "$APP"
  mkdir -p "$RUN_OUT/screenshots"
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
      "$RUN_OUT/screenshots/$tab.png"
    xcrun simctl terminate "$SIMULATOR" com.jonnyt.mp3shelf || true
  done
  echo "Screenshots captured; visual/accessibility review is still required."
fi

echo "Local checks finished; report: $OUT/QA_RECORD.md"
