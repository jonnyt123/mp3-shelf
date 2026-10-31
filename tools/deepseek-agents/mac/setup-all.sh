#!/usr/bin/env bash
# ONE guided command for the connected Cloudflare Free + DeepSeek + Mac + GitHub stack.
# Safe to rerun; does not create paid infrastructure or resume the development queue.
set -euo pipefail
[[ "$(uname -s)" == "Darwin" && "$EUID" -ne 0 ]] || {
  echo "Run as your regular macOS user, not sudo." >&2; exit 1;
}
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
[[ -d .git ]] || { echo "Please run from a git clone, not a downloaded ZIP." >&2; exit 1; }
branch="$(git branch --show-current)"
[[ "$branch" == "agent/mp3-deepseek-low-cost-worker" ]] || {
  echo "Wrong branch: $branch. Use agent/mp3-deepseek-low-cost-worker." >&2; exit 1;
}
echo "MP3 Shelf — one-time guided connection to your EXISTING Cloudflare Worker."
echo "No Oracle, no paid hosting, no GitHub Actions, and no ChatGPT scheduled tasks."
echo "Your 5-agent queue will remain PAUSED throughout this setup."
echo ""
echo "[1/7] Checking/installing prerequisites..."
bash tools/deepseek-agents/mac/install-prerequisites.sh
# Child shells cannot export new Homebrew environment to their parent.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v node >/dev/null || { echo "Reopen Terminal and rerun to activate Homebrew Node." >&2; exit 1; }
command -v opencode >/dev/null || { echo "Reopen Terminal and rerun to activate OpenCode." >&2; exit 1; }
echo "[2/7] Running offline safety tests (no paid model requests)..."
node --test \
  tools/deepseek-agents/runner.test.mjs \
  tools/deepseek-agents/publish.test.mjs \
  tools/deepseek-agents/mac/mac-publisher.test.mjs \
  tools/deepseek-agents/cloudflare/worker.test.mjs
echo "[3/7] Connecting Cloudflare (browser OAuth login may be required once)..."
bash tools/deepseek-agents/cloudflare/connect-existing.sh
echo "[4/7] Connecting the Mac and DeepSeek (hidden key entry only if needed)..."
bash tools/deepseek-agents/cloudflare/install-mac-coordinator.sh
echo "[5/7] Installing GitHub draft-PR publishing (separate limited PAT)..."
sudo bash tools/deepseek-agents/mac/install-mac-publisher.sh
echo "[6/7] Installing independent Mac Xcode/simulator QA..."
bash tools/deepseek-agents/mac/install-mac.sh
echo "[7/7] Installing GitHub QA result reporting (different limited PAT)..."
sudo bash tools/deepseek-agents/mac/install-status-reporter.sh
echo ""
echo "Checking the live Cloudflare queue and read-only DeepSeek API balance..."
if ! node tools/deepseek-agents/cloudflare/mac-client.mjs --doctor; then
  echo "The DeepSeek API balance check is not available. All agents stay PAUSED." >&2
  echo "Check your DeepSeek Console API access before resuming."
fi
echo ""
echo "Mac/cloud setup finished. No paid model calls have started."
echo "Dashboard: https://mp3-shelf-coordinator.mp3shelf-jonny.workers.dev/"
echo "Dashboard token (copies locally without printing):"
echo '  pbcopy < "$HOME/Library/Application Support/MP3ShelfCloudCoordinator/coordinator-token"'
echo "When you choose to run a real paid DeepSeek coding session:"
echo "  node tools/deepseek-agents/cloudflare/mac-client.mjs --resume"
echo "To pause new sessions:"
echo "  node tools/deepseek-agents/cloudflare/mac-client.mjs --pause"
echo "Keep your Mac awake and logged in for background work; no production merge is enabled."
