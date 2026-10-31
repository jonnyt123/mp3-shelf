#!/usr/bin/env bash
# Install a login-session Mac service. Only starts work after explicit --resume.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'This installer requires macOS'; exit 1; }
command -v node >/dev/null || { echo 'Node.js 22+ required'; exit 1; }
src="$(cd "$(dirname "$0")" && pwd)"
root="$HOME/Library/Application Support/MP3ShelfCloudCoordinator"
mkdir -p "$root" "$HOME/Library/LaunchAgents"
umask 077
token="$(cat "$root/coordinator-token")"
[[ "$token" =~ ^[a-f0-9]{64}$ ]] || { echo 'Deploy the Cloudflare service first to create token'; exit 1; }
read -r -p 'Cloudflare workers.dev HTTPS URL: ' url
[[ "$url" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || { echo 'Expected HTTPS workers.dev URL'; exit 1; }
url="$(printf '%s' "$url" | sed 's:/$::')"
read -r -s -p 'DeepSeek API key (hidden; stays on Mac): ' deepseek
printf '\n'
[[ "$deepseek" =~ ^[A-Za-z0-9_.-]{12,}$ ]] || { echo 'Invalid DeepSeek key format'; exit 1; }
printf '{"workerUrl":"%s","coordinatorToken":"%s","deepseekApiKey":"%s"}\n' "$url" "$token" "$deepseek" > "$root/credentials.json"
chmod 0600 "$root/credentials.json"
unset deepseek token
node "$src/mac-client.mjs" --status
node "$src/mac-client.mjs" --seed
plist="$HOME/Library/LaunchAgents/com.mp3shelf.cloud-coordinator.plist"
nodebin="$(command -v node)"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList/1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.mp3shelf.cloud-coordinator</string>
<key>ProgramArguments</key><array>
<string>$nodebin</string>
<string>$src/mac-client.mjs</string><string>--loop</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$root/worker.log</string>
<key>StandardErrorPath</key><string>$root/worker-errors.log</string>
</dict></plist>
PLIST
plutil -lint "$plist"
launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Cloudflare Mac coordinator installed; starts after login while Mac is awake."
echo "Service is PAUSED until you run: node $src/mac-client.mjs --resume"
echo "Pause at any point: node $src/mac-client.mjs --pause"
