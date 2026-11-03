#!/bin/bash
# Double-click from Finder on a Mac with Xcode and an iPhone Simulator runtime.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if /bin/bash "$SCRIPT_DIR/scripts/verify-local-release.sh" --smoke; then
    echo "Verification finished. Review the screenshots and complete physical iPhone QA."
    result=0
else
    result=$?
    echo "Verification stopped (exit $result). Review the report and logs."
fi
if [[ "$(uname -s)" == Darwin && -f "$SCRIPT_DIR/build/local-release/QA_RECORD.md" ]]; then
    open -R "$SCRIPT_DIR/build/local-release/QA_RECORD.md"
fi
read -r -p "Press Return to close. " _ || true
exit "$result"
