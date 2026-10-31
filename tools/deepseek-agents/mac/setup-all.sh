#!/usr/bin/env bash
# One-time opt-in setup for the no-card Cloudflare + DeepSeek + GitHub + Mac QA stack.
# Requires the operator to authenticate directly in Cloudflare and enter keys locally.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo "Requires macOS"; exit 1; }
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
[[ -d .git ]] || { echo "Use a full git clone of jonnyt123/mp3-shelf"; exit 1; }
branch="$(git branch --show-current)"
[[ "$branch" == "agent/mp3-deepseek-low-cost-worker" ]] || {
  echo "Checkout the agent setup branch first; current branch is: $branch"; exit 1;
}
command -v node >/dev/null || { echo "Node.js 22+ required"; exit 1; }
command -v npm >/dev/null || exit 1
command -v git >/dev/null || exit 1
command -v xcodebuild >/dev/null || { echo "Xcode is required for Mac QA"; exit 1; }
command -v opencode >/dev/null || {
  echo "OpenCode 2 CLI required before enabling a paid DeepSeek worker"; exit 1;
}
echo "MP3 Shelf setup — verifies without running paid model calls."
node --test tools/deepseek-agents/runner.test.mjs \
  tools/deepseek-agents/publish.test.mjs \
  tools/deepseek-agents/mac/mac-publisher.test.mjs \
  tools/deepseek-agents/cloudflare/worker.test.mjs
echo "1/5 Connect to the existing MP3 Shelf Cloudflare Worker and rotate the local token..."
bash tools/deepseek-agents/cloudflare/connect-existing.sh
echo "2/5 Connecting Mac (secure local DeepSeek key entry; starts PAUSED)..."
bash tools/deepseek-agents/cloudflare/install-mac-coordinator.sh
echo "3/5 Connecting independent GitHub draft publisher..."
sudo bash tools/deepseek-agents/mac/install-mac-publisher.sh
echo "4/5 Installing Mac unsigned Xcode QA poller..."
bash tools/deepseek-agents/mac/install-mac.sh
echo "5/5 Installing independent, status-only GitHub report daemon..."
sudo bash tools/deepseek-agents/mac/install-status-reporter.sh
echo "READ-ONLY verification of Cloudflare and DeepSeek account balance:"
node tools/deepseek-agents/cloudflare/mac-client.mjs --doctor
echo "Setup completed but coordinator remains paused. Review balance and dashboard first."
echo "Dashboard URL: the workers.dev address printed by Wrangler."
echo "To begin the FIRST live coding cycle when ready:"
echo "  node tools/deepseek-agents/cloudflare/mac-client.mjs --resume"
echo "  node tools/deepseek-agents/cloudflare/mac-client.mjs --once"
echo "No auto-merge or production release is enabled. Hardware gate #6 remains in force."
