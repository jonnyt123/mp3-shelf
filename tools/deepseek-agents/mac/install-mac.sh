#!/usr/bin/env bash
# Install local, unprivileged Mac QA poller. No token, no inbound SSH, no ChatGPT scheduling.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo "macOS required"; exit 1; }
command -v xcodebuild >/dev/null || { echo "Install Xcode and select its developer path first"; exit 1; }
src="$(cd "$(dirname "$0")" && pwd)"
install -d -m 0700 "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/MP3ShelfCloudQA"
install -m 0700 "$src/mac-qa.sh" "$HOME/.local/bin/mp3-shelf-mac-qa"
plist="$HOME/Library/LaunchAgents/com.mp3shelf.cloudqa.plist"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.mp3shelf.cloudqa</string>
<key>ProgramArguments</key><array>
<string>/bin/bash</string><string>$HOME/.local/bin/mp3-shelf-mac-qa</string>
</array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>900</integer>
<key>StandardOutPath</key><string>$HOME/Library/Application Support/MP3ShelfCloudQA/launch-out.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Application Support/MP3ShelfCloudQA/launch-error.log</string>
</dict></plist>
PLIST
plutil -lint "$plist"
launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Mac QA installed. It fetches new agent branches whenever the Mac is awake."
echo "Reports: $HOME/Library/Application Support/MP3ShelfCloudQA/reports"
echo "Install the SEPARATE root-only status broker to publish GitHub commit statuses."
