#!/usr/bin/env bash
# Idempotent macOS prerequisites for MP3 Shelf. Never starts paid model calls.
set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "This setup requires macOS." >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || { echo "Run as your normal Mac login, not sudo." >&2; exit 1; }
# Brew might be installed but not exported into an interactive shell yet.
if ! command -v brew >/dev/null 2>&1; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install Node.js and OpenCode safely." >&2
  echo "Install it from https://brew.sh and rerun this same command. No payment method is needed." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "Git is missing. Run xcode-select --install once, then rerun." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode must be installed and selected for iOS builds." >&2
  echo "Open Xcode at least once to accept its license, then run sudo xcode-select -s /Applications/Xcode.app/Contents/Developer if needed." >&2
  exit 1
fi
major=0
if command -v node >/dev/null 2>&1; then
  major="$(node -p 'parseInt(process.versions.node.split(".")[0],10)' 2>/dev/null || printf 0)"
fi
if [[ ! "$major" =~ ^[0-9]+$ ]] || (( major < 22 )); then
  echo "Installing current Node.js using Homebrew (requires Node 22+)..."
  if brew list --formula node >/dev/null 2>&1; then
    brew upgrade node
  else
    brew install node
  fi
fi
node -e 'if (parseInt(process.versions.node.split(".")[0],10)<22) process.exit(1)' || {
  echo "Node 22+ is not on PATH after installation. Open a new Terminal session." >&2
  exit 1
}
if ! command -v opencode >/dev/null 2>&1; then
  echo "Installing OpenCode V2 with the official Homebrew tap..."
  brew install anomalyco/tap/opencode-v2
fi
version="$(opencode --version 2>/dev/null || true)"
if [[ ! "$version" =~ ^2\. ]]; then
  echo "OpenCode V2 is required; found: $version" >&2
  echo "OpenCode V1 conflicts with V2. Review your installed OpenCode version before continuing." >&2
  exit 1
fi
if ! opencode run --help 2>&1 | grep -q -- '--agent'; then
  echo "OpenCode V2 'run --agent' support is not available." >&2
  exit 1
fi
echo "Prerequisites: Git $(git --version), Node $(node --version), OpenCode $version, Xcode $(xcodebuild -version | head -1)."
