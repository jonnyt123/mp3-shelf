#!/bin/bash
# Build/sign the project selected in this folder; do not install or launch.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if /bin/bash "$SCRIPT_DIR/scripts/run-on-iphone.sh" --diagnose; then
    result=0
else
    result=$?
fi
report="$SCRIPT_DIR/build/iphone-device/QA_RECORD.md"
if [[ "$(uname -s)" == Darwin && -f "$report" ]]; then
    open "$report"
fi
printf '\nReport: %s\n' "$report"
read -r -p "Press Return to close. " _ || true
exit "$result"
