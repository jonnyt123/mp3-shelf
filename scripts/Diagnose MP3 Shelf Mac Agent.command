#!/bin/bash
# Double-click: inspect this Mac and safely re-bootstrap only our unloaded LaunchAgent.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
 echo "MP3 Shelf native automation diagnostics require macOS." >&2; exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if ! command -v node >/dev/null || [[ ! -f "$ROOT/scripts/mac-agent-health.mjs" ]]; then
 echo "Node.js and MP3 Shelf release tools are required." >&2; exit 2
fi
echo "Checking Xcode, Apple developer selection, launchd registration, and latest native run..."
node "$ROOT/scripts/mac-agent-health.mjs" --repair || {
 echo "No unrelated services, source files, signing settings or stale locks were changed." >&2
 echo "See the checks above. For a missing agent, run the existing Install MP3 Shelf Native Agent.command." >&2
 exit 1
}
echo "Mac agent is loaded and has a recent run receipt. Native Xcode acceptance is a separate gate."
