#!/usr/bin/env bash
# Foundation-only queue regression suite. Runs without Xcode Simulator or signing.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if command -v xcrun >/dev/null 2>&1; then
  compiler=(xcrun swiftc)
else
  compiler=(swiftc)
fi

"${compiler[@]}" "$repo/ios/MP3Shelf/Models/PlaybackOrder.swift" "$repo/ios/Tests/PlaybackOrderTests.swift" -o "$work/playback-order-tests"
"$work/playback-order-tests"
