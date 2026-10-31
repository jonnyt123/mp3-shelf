#!/usr/bin/env bash
# One-time macOS installation of a root-owned PR publisher; never run this from an agent.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$EUID" -eq 0 ]] || { echo 'Run with sudo on macOS'; exit 1; }
[[ -n "$SUDO_USER" && "$SUDO_USER" != root ]] || { echo 'Run using sudo from your normal Mac login'; exit 1; }
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v node >/dev/null || { echo 'Node 22+ required; install Homebrew Node first'; exit 1; }
command -v git >/dev/null || exit 1
src="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$src/../../.." && pwd)"
[[ "$repo" == /* && -d "$repo/.git" ]] || { echo 'Run from a full MP3 Shelf clone (not a ZIP)'; exit 1; }
home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')"
[[ -n "$home" ]] || exit 1
nodebin="$(command -v node)"
broker="/Library/Application Support/MP3ShelfPublisher"
install -d -o root -g wheel -m 0700 "$broker"
install -o root -g wheel -m 0700 "$src/mac-publisher.mjs" "$broker/mac-publisher.mjs"
cat > "$broker/askpass.sh" <<'SH'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token';;
  *Password*) cat '/Library/Application Support/MP3ShelfPublisher/publisher.token';;
  *) exit 1;;
esac
SH
chown root:wheel "$broker/askpass.sh"
chmod 0700 "$broker/askpass.sh"
umask 077
if [[ -s "$broker/publisher.token" ]]; then
  echo 'Using existing root-protected publisher token (no repeated prompt).'
else
  read -r -s -p 'GitHub fine-grained PAT (mp3-shelf ONLY: Contents + Pull requests write): ' token
  printf '\n'
  if [[ ! "$token" =~ ^[A-Za-z0-9_]{25,}$ ]]; then echo 'Invalid PAT format'; exit 1; fi
  printf '%s' "$token" > "$broker/publisher.token"
  unset token
fi
chown root:wheel "$broker/publisher.token"
chmod 0600 "$broker/publisher.token"
plist="/Library/LaunchDaemons/com.mp3shelf.publisher.plist"
evidence="$(dirname "$repo")/.mp3-shelf-agent-state/approved"
"/usr/bin/python3" - "$plist" "$nodebin" "$broker/mac-publisher.mjs" "$repo" "$evidence" <<'PY'
import plistlib,sys
target,node,script,repo,evidence=sys.argv[1:]
data={
 'Label':'com.mp3shelf.publisher',
 'ProgramArguments':[node,script],
 'EnvironmentVariables':{'MP3_SOURCE_REPO':repo,'MP3_EVIDENCE_DIR':evidence},
 'RunAtLoad':True,'StartInterval':300,'ProcessType':'Background',
 'StandardOutPath':'/Library/Application Support/MP3ShelfPublisher/publisher.log',
 'StandardErrorPath':'/Library/Application Support/MP3ShelfPublisher/publisher-error.log'
}
with open(target,'wb') as f: plistlib.dump(data,f)
PY
chown root:wheel "$plist"
chmod 0644 "$plist"
plutil -lint "$plist"
launchctl bootout system "$plist" >/dev/null 2>&1 || true
launchctl bootstrap system "$plist"
echo 'Root-only Mac publisher installed; auto-publishes only validated agent branches as draft PRs.'
echo 'Disable: sudo launchctl bootout system /Library/LaunchDaemons/com.mp3shelf.publisher.plist'
