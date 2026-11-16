#!/bin/bash
# One-click synthetic draft-only upload check; NEVER publishes a GitHub Release.
set -euo pipefail
umask 077
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This test needs macOS, GitHub CLI authentication, and Node." >&2; exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
for bin in node gh git osascript; do
  command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 2; }
done
[[ -f "$ROOT/scripts/smoke-draft-release.mjs" ]] || {
  echo "The release smoke script is missing from this checkout." >&2; exit 2
}
osascript -e 'display dialog "Run a draft-only GitHub upload test with a tiny synthetic ZIP and manifest? The test will verify remote and downloaded bytes, then DELETE its own draft release and tag. It cannot publish a release." buttons {"Cancel", "Run Draft Test"} default button "Cancel" with icon caution' >/dev/null
LOG_DIR="$HOME/Library/Logs/MP3Shelf/ReleaseSmoke"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$$.log"
echo "Testing GitHub draft-only upload; no real music or app files are included."
node "$ROOT/scripts/smoke-draft-release.mjs" --live-draft-smoke "$ROOT" | tee "$LOG"
echo "Receipt: $LOG"
echo "No final native project ZIP was released."
