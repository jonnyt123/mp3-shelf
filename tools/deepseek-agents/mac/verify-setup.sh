#!/usr/bin/env bash
# Read-only post-install verification. Never sends a paid model request or pushes Git.
set -uo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "This check requires macOS"; exit 1; }
src="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$src/../../.." && pwd)"
store="$HOME/Library/Application Support/MP3ShelfCloudCoordinator"
failed=0
check() {
  if "$@" >/dev/null 2>&1; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'CHECK %s\n' "$1"
    failed=$((failed+1))
  fi
}
echo "MP3 Shelf — Mac connection diagnostics (no paid model calls)"
if [[ -s "$store/coordinator-token" ]]; then
  token_length="$(wc -c < "$store/coordinator-token" | tr -d '[:space:]')"
  if [[ "$token_length" == 65 ]]; then echo "PASS  Coordinator token stored locally"; else echo "CHECK Coordinator token format"; failed=$((failed+1)); fi
else
  echo "CHECK Coordinator token missing"; failed=$((failed+1))
fi
if [[ -s "$store/credentials.json" ]]; then
  echo "PASS  Private DeepSeek/Cloudflare settings exist (not displayed)"
else
  echo "CHECK Mac credentials missing"; failed=$((failed+1))
fi
if [[ -f "$HOME/Library/LaunchAgents/com.mp3shelf.cloud-coordinator.plist" ]]; then
  echo "PASS  Mac coordinator LaunchAgent installed"
else
  echo "CHECK Mac coordinator LaunchAgent not installed"; failed=$((failed+1))
fi
if [[ -f "$HOME/Library/LaunchAgents/com.mp3shelf.cloudqa.plist" ]]; then
  echo "PASS  Native Xcode QA LaunchAgent installed"
else
  echo "CHECK Xcode QA LaunchAgent not installed"; failed=$((failed+1))
fi
if [[ -f /Library/LaunchDaemons/com.mp3shelf.publisher.plist ]]; then
  echo "PASS  GitHub draft publisher LaunchDaemon installed"
else
  echo "CHECK GitHub draft publisher not installed"; failed=$((failed+1))
fi
if [[ -f /Library/LaunchDaemons/com.mp3shelf.cloudqa.reporter.plist ]]; then
  echo "PASS  GitHub Xcode status LaunchDaemon installed"
else
  echo "CHECK GitHub Xcode status reporter not installed"; failed=$((failed+1))
fi
if node "$root/tools/deepseek-agents/cloudflare/mac-client.mjs" --status >/dev/null 2>&1; then
  echo "PASS  Live authenticated Cloudflare coordinator API"
else
  echo "CHECK Cloudflare API unreachable or token out of sync"; failed=$((failed+1))
fi
if node "$root/tools/deepseek-agents/cloudflare/mac-client.mjs" --doctor >/dev/null 2>&1; then
  echo "PASS  Read-only DeepSeek API balance endpoint"
else
  echo "CHECK DeepSeek key or API balance endpoint (no paid request made)"; failed=$((failed+1))
fi
if [[ "$failed" == 0 ]]; then
  echo "Connectivity and installation checks passed; a real coding/Xcode cycle is NOT verified."
else
  echo "$failed setup checks require attention; coordinator remains paused unless you explicitly resume it."
fi
echo "Dashboard: https://mp3-shelf-coordinator.mp3shelf-jonny.workers.dev/"
echo "Copy dashboard token without printing it:"
echo '  pbcopy < "$HOME/Library/Application Support/MP3ShelfCloudCoordinator/coordinator-token"'
exit $(( failed>0 ))
