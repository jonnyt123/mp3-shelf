#!/usr/bin/env bash
# Mac root-only status reporter. The Swift build process never receives this token.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$EUID" -eq 0 ]] || { echo "Run using sudo on macOS"; exit 1; }
user="$SUDO_USER"
[[ -n "$user" && "$user" != root ]] || { echo "Use sudo from Mac QA account"; exit 1; }
home="$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')"
[[ -d "$home" ]] || exit 1
src="$(cd "$(dirname "$0")" && pwd)"
root="/Library/Application Support/MP3ShelfCloudQA"
install -d -o root -g wheel -m 0700 "$root"
install -o root -g wheel -m 0700 "$src/report-status.py" "$root/report-status.py"
umask 077
read -r -s -p "GitHub PAT (mp3-shelf: Commit statuses write, Contents read): " token
printf '\n'
[[ "$token" =~ ^[A-Za-z0-9_]+$ ]] && [[ "$token" != "" ]] || { echo "Invalid token"; exit 1; }
printf '%s' "$token" > "$root/status-token"
chmod 0600 "$root/status-token"
unset token
/usr/bin/python3 - "$root/reporter.json" "$home/Library/Application Support/MP3ShelfCloudQA/reports" <<'PY'
import json,sys
with open(sys.argv[1],"w") as f: json.dump({"reports":sys.argv[2]},f)
PY
chmod 0600 "$root/reporter.json"
plist="/Library/LaunchDaemons/com.mp3shelf.cloudqa.reporter.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.mp3shelf.cloudqa.reporter</string>
<key>ProgramArguments</key><array>
<string>/usr/bin/python3</string>
<string>/Library/Application Support/MP3ShelfCloudQA/report-status.py</string>
</array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>900</integer>
<key>StandardOutPath</key><string>/Library/Application Support/MP3ShelfCloudQA/reporter-out.log</string>
<key>StandardErrorPath</key><string>/Library/Application Support/MP3ShelfCloudQA/reporter-error.log</string>
</dict></plist>
PLIST
chown root:wheel "$plist"
chmod 0644 "$plist"
plutil -lint "$plist"
launchctl bootout system "$plist" >/dev/null 2>&1 || true
launchctl bootstrap system "$plist"
echo "Root-only status reporter enabled; test processes never receive token environment variables."
