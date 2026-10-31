#!/usr/bin/env bash
# Configures a user-level Mac coordinator for the ALREADY deployed Cloudflare Worker.
set -euo pipefail
[[ "$(uname -s)" == "Darwin" && "$EUID" -ne 0 ]] || { echo "Run under your normal Mac account" >&2; exit 1; }
command -v node >/dev/null || { echo "Node 22+ required" >&2; exit 1; }
src="$(cd "$(dirname "$0")" && pwd)"
root="$HOME/Library/Application Support/MP3ShelfCloudCoordinator"
url="https://mp3-shelf-coordinator.mp3shelf-jonny.workers.dev"
mkdir -p "$root" "$HOME/Library/LaunchAgents"
chmod 0700 "$root"
umask 077
token="$(cat "$root/coordinator-token")"
[[ "$token" =~ ^[a-f0-9]{64}$ ]] || { echo "Connect to Cloudflare before configuring Mac" >&2; exit 1; }
deepseek=""
config="$root/credentials.json"
if [[ -f "$config" ]]; then
  [[ ! -L "$config" ]] || { echo "Unsafe credentials symlink" >&2; exit 1; }
  deepseek="$(node -e 'const fs=require("fs");const p=process.argv[1];const s=fs.statSync(p);if((s.mode&0o077)!==0)process.exit(2);let v=JSON.parse(fs.readFileSync(p,"utf8")).deepseekApiKey||"";if(/^[A-Za-z0-9_.-]{12,}$/.test(v))process.stdout.write(v)' "$config")"
fi
if [[ -z "$deepseek" ]]; then
  read -r -s -p "DeepSeek Console API key (hidden, stored only on your Mac): " deepseek
  printf '\n'
fi
[[ "$deepseek" =~ ^[A-Za-z0-9_.-]{12,}$ ]] || { echo "Invalid DeepSeek API key format" >&2; exit 1; }
printf '{"workerUrl":"%s","coordinatorToken":"%s","deepseekApiKey":"%s"}\n' "$url" "$token" "$deepseek" > "$config.tmp"
chmod 0600 "$config.tmp"
mv -f "$config.tmp" "$config"
unset deepseek token
node "$src/mac-client.mjs" --status >/dev/null
node "$src/mac-client.mjs" --seed >/dev/null
plist="$HOME/Library/LaunchAgents/com.mp3shelf.cloud-coordinator.plist"
nodebin="$(command -v node)"
# plistlib escapes spaces/special characters in paths safely.
python3 - "$plist" "$nodebin" "$src/mac-client.mjs" "$root" <<'PY'
import plistlib,sys
p,node,script,root=sys.argv[1:]
data={
 "Label":"com.mp3shelf.cloud-coordinator",
 "ProgramArguments":[node,script,"--loop"],
 "RunAtLoad":True,"KeepAlive":True,
 "StandardOutPath":root+"/worker.log",
 "StandardErrorPath":root+"/worker-errors.log"
}
with open(p,"wb") as f: plistlib.dump(data,f)
PY
plutil -lint "$plist" >/dev/null
launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Mac connected to your existing Cloudflare Worker. The queue remains paused."
echo "Open the dashboard: $url"
echo "To copy your coordinator token into the clipboard, run:"
echo "  pbcopy < \"$root/coordinator-token\""
