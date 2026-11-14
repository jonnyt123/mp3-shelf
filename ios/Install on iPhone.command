#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "A Mac with full Xcode is required."
    exit 2
fi
printf 'Connect and unlock your iPhone. Sign into Xcode Settings > Accounts first.\n'
if ! xcrun devicectl list devices; then exit 2; fi
read -r -p "Paste your iPhone identifier from the list: " device
read -r -p "Enter your 10-character Apple Team ID: " team
report="$SCRIPT_DIR/build/iphone-device/QA_RECORD.md"
previous_report="$(cksum "$report" 2>/dev/null || true)"
if MP3SHELF_TEAM_ID="$team" /bin/bash "$SCRIPT_DIR/scripts/run-on-iphone.sh" "$device"; then
    result=0
else
    result=$?
fi
if [[ "$result" -ne 0 && -f "$report" &&
      "$(cksum "$report")" != "$previous_report" ]]; then
    open "$report"
fi
read -r -p "Press Return to close. " _ || true
exit "$result"
