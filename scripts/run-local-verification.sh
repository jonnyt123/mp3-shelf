#!/usr/bin/env bash
# Run repository verification on an owned machine, never GitHub Actions.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
usage() {
  cat <<'HELP'
MP3 Shelf — local verification without GitHub Actions minutes
  bash scripts/run-local-verification.sh --node-only
  bash scripts/run-local-verification.sh --web [--offline]
  bash scripts/run-local-verification.sh --native [--smoke]
  bash scripts/run-local-verification.sh --all [--offline] [--smoke]
--node-only : release evidence and rollback safety unit tests; no npm install
--web       : Node safety tests, npm ci if needed, web tests, typecheck, build
--native    : existing ios/scripts/verify-local-release.sh (macOS/Xcode required)
--all       : web followed by native; no automatic deploy, signing or CI
--offline   : npm ci uses only local npm cache; errors if cache incomplete
--smoke     : native Simulator smoke/snapshots; not physical iPhone QA
Reports/logs are kept under your system temporary directory.
HELP
}
MODE=web; OFFLINE=false; SMOKE=false; MODE_SET=false
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --node-only|--web|--native|--all)
      if [[ "$MODE_SET" == true ]]; then echo 'ERROR: Choose one mode.' >&2; exit 2; fi
      MODE="${1#--}"; MODE_SET=true ;;
    --offline) OFFLINE=true ;;
    --smoke) SMOKE=true ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [[ "$SMOKE" == true && "$MODE" != native && "$MODE" != all ]]; then echo 'ERROR: --smoke requires native mode.' >&2; exit 2; fi
cd "$ROOT"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/mp3-shelf-verification.XXXXXXXX")"
COMMIT="$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)"
DIRTY=unknown
if [[ "$COMMIT" != unknown ]]; then DIRTY=no; [[ -z "$(git status --porcelain)" ]] || DIRTY=yes; fi
STEP=none; COMPLETED=()
report() {
  code=$?
  {
    echo "Mode: $MODE"
    echo "Candidate commit: $COMMIT"
    echo "Dirty checkout: $DIRTY"
    echo "Completed: ${COMPLETED[*]:-none}"
    echo "Last attempted: $STEP"
    echo "Exit status: $code"
    echo "Native physical iPhone acceptance: NOT TESTED"
    echo "GitHub Actions minutes used: ZERO"
    echo "Logs: $OUT"
    [[ "$code" == 0 ]] && echo 'Local execution: PASS (only for completed steps)' || echo 'Local execution: FAIL'
  } | tee "$OUT/QA_RECORD.txt"
}
trap report EXIT
run() {
  STEP="$1"; shift
  echo "==> $STEP"
  "$@" 2>&1 | tee "$OUT/$STEP.log"
  COMPLETED+=("$STEP")
}
if [[ "$MODE" == node-only || "$MODE" == web || "$MODE" == all ]]; then
  run node-release-safety node --test scripts/verify-release-evidence.test.mjs scripts/verify-vercel-release.test.mjs
fi
if [[ "$MODE" == web || "$MODE" == all ]]; then
  if [[ ! -d node_modules ]]; then
    if [[ "$OFFLINE" == true ]]; then
      run npm-ci-offline npm ci --offline --no-audit --no-fund
    else
      run npm-ci npm ci --prefer-offline --no-audit --no-fund
    fi
  fi
  run npm-test npm test
  run npm-typecheck npm run typecheck
  run npm-build npm run build
fi
if [[ "$MODE" == native || "$MODE" == all ]]; then
  if [[ "$(uname -s)" != Darwin || ! -x "$(command -v xcodebuild || echo /nonexistent)" ]]; then
    echo 'ERROR: Native verification needs a Mac with full Xcode; not verified here.' >&2
    exit 2
  fi
  if [[ ! -f ios/scripts/verify-local-release.sh ]]; then
    echo 'ERROR: Native candidate sources are absent from this checkout.' >&2
    exit 2
  fi
  native_args=()
  [[ "$SMOKE" != true ]] || native_args+=(--smoke)
  run native-local-release bash ios/scripts/verify-local-release.sh "${native_args[@]}"
fi
