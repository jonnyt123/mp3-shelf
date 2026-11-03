#!/bin/bash
# MP3 Shelf — double-click Mac installer. No commands need to be typed by the user.
# Uses the real repository setup-all.sh, never runs an unreviewed curl | bash pipeline.
set -Eeuo pipefail
umask 077
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

REPOSITORY="https://github.com/jonnyt123/mp3-shelf.git"
EXPECTED_BRANCH="agent/mp3-deepseek-low-cost-worker"
INSTALL_DIR="$HOME/MP3ShelfAgents"
DASHBOARD="https://mp3-shelf-coordinator.mp3shelf-jonny.workers.dev/"
INSTALL_FAILED=0

show_dialog() {
  local title="$1" text="$2"
  /usr/bin/osascript - "$title" "$text" <<'OSA'
on run argv
  set dialogTitle to item 1 of argv
  set dialogMessage to item 2 of argv
  display dialog dialogMessage with title dialogTitle buttons {"OK"} default button "OK" with icon note
end run
OSA
}

confirm_install() {
  /usr/bin/osascript <<'OSA'
set descriptionText to "This installs the MP3 Shelf development services on your Mac. It connects to your existing free Cloudflare Worker, checks Xcode, Git, Node.js and OpenCode, and configures the background agent coordinator. You may be asked to sign in to Cloudflare and enter DeepSeek and GitHub credentials. No DeepSeek coding calls or automatic merges start during installation."
try
  display dialog descriptionText with title "MP3 Shelf Setup" buttons {"Cancel", "Install"} default button "Install" with icon note
on error number -128
  error number -128
end try
OSA
}

on_exit() {
  local code="$?"
  trap - EXIT
  if (( code != 0 )) && (( INSTALL_FAILED == 0 )); then
    INSTALL_FAILED=1
    printf '\nMP3 Shelf setup stopped (exit %s). Review the details shown above.\n' "$code" >&2
    show_dialog "MP3 Shelf — Setup Incomplete" "The installation stopped before completion. The Terminal window shows the reason and any safe repair instructions. Nothing has been merged into production, and this installer does not deliberately start paid DeepSeek jobs." || true
  fi
  if [[ -t 0 ]]; then
    printf '\nYou can close this window when finished.\n'
  fi
  exit "$code"
}
trap on_exit EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS only." >&2
  exit 1
fi
if [[ "$EUID" -eq 0 ]]; then
  echo "Run the installer by double-clicking it as your normal Mac user, not root." >&2
  exit 1
fi

if ! confirm_install; then
  echo "Installation cancelled."
  INSTALL_FAILED=1
  exit 0
fi

printf '\n=====================================================\n'
printf ' MP3 Shelf — One-Click Mac Setup\n'
printf '=====================================================\n'
printf 'Existing Cloudflare Worker: %s\n' "$DASHBOARD"
printf 'Install location: %s\n' "$INSTALL_DIR"
printf 'No API keys will be echoed or stored in GitHub.\n\n'

if ! command -v git >/dev/null 2>&1; then
  printf 'Git is not yet installed. Opening Apple Command Line Tools setup...\n'
  /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  show_dialog "Install Git Tools" "macOS needs Apple Command Line Tools before MP3 Shelf can be downloaded. Complete the Apple installation window, then double-click Install MP3 Shelf.command again. No commands need to be typed."
  INSTALL_FAILED=1
  exit 1
fi

if [[ -e "$INSTALL_DIR" ]]; then
  if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    echo "Existing directory is not a Git checkout: $INSTALL_DIR" >&2
    echo "For your protection the installer will not delete or replace it." >&2
    exit 1
  fi
  actual_origin="$(git -C "$INSTALL_DIR" remote get-url origin)"
  case "$actual_origin" in
    "$REPOSITORY"|"https://github.com/jonnyt123/mp3-shelf"|"git@github.com:jonnyt123/mp3-shelf.git") ;;
    *) echo "Existing checkout has an unexpected Git origin. Nothing was changed." >&2; exit 1 ;;
  esac
  current_branch="$(git -C "$INSTALL_DIR" branch --show-current)"
  if [[ "$current_branch" != "$EXPECTED_BRANCH" ]]; then
    printf 'Expected branch: %s\nFound branch: %s\n' "$EXPECTED_BRANCH" "$current_branch" >&2
    echo "Refusing to change an existing checkout on a different branch." >&2
    exit 1
  fi
  if [[ -n "$(git -C "$INSTALL_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "Existing checkout contains uncommitted files. Preserving them without updating." >&2
    echo "Use a clean MP3ShelfAgents checkout before continuing." >&2
    exit 1
  fi
  echo '[1/3] Updating existing MP3 Shelf agent setup safely...'
  git -C "$INSTALL_DIR" pull --ff-only origin "$EXPECTED_BRANCH"
else
  echo '[1/3] Downloading the MP3 Shelf agent setup from GitHub...'
  git clone --single-branch --branch "$EXPECTED_BRANCH" "$REPOSITORY" "$INSTALL_DIR"
fi

if [[ ! -f "$INSTALL_DIR/tools/deepseek-agents/mac/setup-all.sh" ]]; then
  echo 'The downloaded source is missing the guided Mac setup script. Aborting.' >&2
  exit 1
fi

printf '\n[2/3] Installing the Mac services with guided prompts...\n'
printf 'Enter keys/passwords only at the specific hidden prompts.\n'
cd "$INSTALL_DIR"
/bin/bash tools/deepseek-agents/mac/setup-all.sh

printf '\n[3/3] Setup complete. Agents are still paused.\n'
printf 'Dashboard: %s\n' "$DASHBOARD"

# Clipboard access requires an explicit user selection; never print the token.
choice="$(/usr/bin/osascript <<'OSA'
set msg to "MP3 Shelf has finished its Mac installation. All five development roles are installed, but paid DeepSeek coding is PAUSED by default. You can open the Cloudflare dashboard and resume later after checking your API balance. Copy your private dashboard token to the clipboard?"
set a to display dialog msg with title "MP3 Shelf — Setup Complete" buttons {"Done", "Copy Token & Open Dashboard"} default button "Copy Token & Open Dashboard" with icon note
return button returned of a
OSA
)" || true
if [[ "$choice" == "Copy Token & Open Dashboard" ]]; then
  TOKEN_FILE="$HOME/Library/Application Support/MP3ShelfCloudCoordinator/coordinator-token"
  if [[ -s "$TOKEN_FILE" ]]; then
    /usr/bin/pbcopy < "$TOKEN_FILE"
    echo 'Coordinator token copied to clipboard; do not paste it into chat.'
  else
    echo 'Coordinator token was not available to copy; inspect the installer verification.'
  fi
  /usr/bin/open "$DASHBOARD"
fi
INSTALL_FAILED=1
exit 0
