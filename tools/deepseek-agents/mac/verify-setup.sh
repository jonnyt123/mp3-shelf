#!/usr/bin/env bash
# Read-only verification; prints targeted fixes, never keys or raw logs.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo "Mac setup verification requires macOS"; exit 1; }
root="$(cd "$(dirname "$0")/../../.." && pwd)"
command -v node >/dev/null || { echo "Node.js 22+ is required for diagnostics."; exit 1; }
exec node "$root/tools/deepseek-agents/mac/diagnose-install.mjs" "$@"
