#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if /bin/bash "$SCRIPT_DIR/scripts/prove-download-path.sh"; then
    result=0
else
    result=$?
    echo "The live download test stopped (exit $result). Review the report and native result."
fi
if [[ "$(uname -s)" == Darwin && -f "$SCRIPT_DIR/build/download-proof/QA_RECORD.md" ]]; then
    open "$SCRIPT_DIR/build/download-proof/QA_RECORD.md"
fi
read -r -p "Press Return to close. " _ || true
exit "$result"
