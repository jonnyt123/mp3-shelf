#!/bin/bash
# One-click read-only dashboard. Does not run Xcode or publish releases.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "MP3 Shelf release dashboard is designed for your Mac." >&2; exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if ! command -v node >/dev/null || [[ ! -f "$ROOT/scripts/release-readiness.mjs" ]]; then
  echo "Node.js and current MP3 Shelf release tooling are required." >&2; exit 2
fi
echo "Refreshing the current release readiness evidence from this Mac and GitHub..."
if node "$ROOT/scripts/release-readiness.mjs"; then
  FILE="$HOME/Library/Logs/MP3Shelf/ReleaseReadiness/latest.html"
  if [[ -f "$FILE" && ! -L "$FILE" ]]; then
    open "$FILE"
    echo "Local read-only release dashboard: $FILE"
  else
    echo "Release readiness HTML was not created; no gates were changed." >&2
    exit 2
  fi
else
  echo "Release readiness is unavailable. The last confirmed dashboard was not updated." >&2
  exit 2
fi
