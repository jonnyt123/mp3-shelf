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
if [[ "$COMMIT" != unknown ]]; then DIRTY=no; [[ -z "$(git status --porcelain --untracked-files=all)" ]] || DIRTY=yes; fi
STEP=none; COMPLETED=(); RECEIPT_STEPS=()
# Release evidence must be bound to a reproducible, clean Git commit.
report() {
  local code=$?
  local receipt_state='NOT_CREATED'
  # Preserve the underlying command's failure. However, a clean successful
  # verification must not exit 0 if its required evidence cannot be produced.
  # Previously "|| true" discarded receipt failures while the summary still
  # advertised PASS, allowing an apparently green but unreviewable run.
  trap - EXIT
  # Revalidate the source at receipt time, not only at the start or after
  # the final test. A failing command, EXIT hook, or intervening process may
  # have changed HEAD or introduced files after the last integrity step.
  # A changed checkout must never produce a successful SHA-bound receipt.
  if [[ "$COMMIT" != unknown && "$DIRTY" == no ]]; then
    if [[ "$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)" != "$COMMIT" ||
          -n "$(git status --porcelain --untracked-files=all 2>/dev/null || echo status-failed)" ]]; then
      receipt_state='UNAVAILABLE_CHECKOUT_CHANGED'
      if [[ "$code" -eq 0 ]]; then
        code=1
        echo 'ERROR: Checkout changed before receipt generation; refusing release evidence.' >&2
      fi
    fi
  fi
  if [[ "$COMMIT" != unknown && "$DIRTY" == no && "$receipt_state" != UNAVAILABLE_CHECKOUT_CHANGED ]]; then
    if node "$ROOT/scripts/local-evidence.mjs" "$OUT/local-evidence.json" "$COMMIT" "$DIRTY" "$MODE" "$code" "$OUT" "${RECEIPT_STEPS[@]}"; then
      receipt_state='CREATED_UNVERIFIED'
      # Receipt creation is not evidence verification. Re-open the persisted
      # JSON and re-hash the original logs while checking the actual Git HEAD.
      # The verifier rejects incomplete receipts even if JSON creation worked.
      if [[ "$code" -eq 0 ]]; then
        if node "$ROOT/scripts/local-evidence.mjs" --verify "$OUT/local-evidence.json" "$COMMIT" "$OUT"; then
          receipt_state='VERIFIED'
        else
          receipt_state='VERIFICATION_FAILED'
          code=1
          echo 'ERROR: Persisted release receipt failed independent verification; refusing PASS.' >&2
        fi
      else
        receipt_state='INCOMPLETE'
      fi
    else
      receipt_state='FAILED'
      if [[ "$code" -eq 0 ]]; then
        code=1
        echo 'ERROR: Verification commands succeeded but receipt generation failed; refusing PASS.' >&2
      fi
    fi
  else
    if [[ "$receipt_state" != UNAVAILABLE_CHECKOUT_CHANGED ]]; then
      receipt_state='UNAVAILABLE_UNCLEAN_CHECKOUT'
    fi
    # Node-only development checks are still runnable on a dirty checkout,
    # but must not be misrepresented as clean, SHA-bound release evidence.
  fi
  {
    echo "Mode: $MODE"
    echo "Candidate commit: $COMMIT"
    echo "Dirty checkout: $DIRTY"
    echo "Completed: ${COMPLETED[*]:-none}"
    echo "Last attempted: $STEP"
    echo "Exit status: $code"
    echo "SHA-bound receipt: $receipt_state"
    echo "Native physical iPhone acceptance: NOT TESTED"
    echo "GitHub Actions minutes used: ZERO"
    echo "Logs: $OUT"
    if [[ "$code" -eq 0 && "$receipt_state" == VERIFIED ]]; then
      echo 'Local execution: PASS (only for completed steps; not release approval)'
    elif [[ "$code" -eq 0 ]]; then
      echo 'Local execution: DEVELOPMENT CHECKS PASSED; NO RELEASE EVIDENCE'
    else
      echo 'Local execution: FAIL'
    fi
  } | tee "$OUT/QA_RECORD.txt"
  exit "$code"
}
trap report EXIT
if [[ "$MODE" != node-only && ( "$COMMIT" == unknown || "$DIRTY" != no ) ]]; then
  STEP=checkout-preflight
  echo "ERROR: Refusing release verification without a clean Git checkout at a known commit." >&2
  exit 2
fi
run() {
  STEP="$1"; shift
  echo "==> $STEP"
  if "$@" 2>&1 | tee "$OUT/$STEP.log"; then
    COMPLETED+=("$STEP")
    RECEIPT_STEPS+=("$STEP:1")
  else
    RECEIPT_STEPS+=("$STEP:0")
    return 1
  fi
}
if [[ "$MODE" == node-only || "$MODE" == web || "$MODE" == all ]]; then
  run node-release-safety node --test scripts/verify-release-evidence.test.mjs scripts/verify-vercel-release.test.mjs scripts/run-local-verification.test.mjs scripts/local-evidence.test.mjs
fi
# Node-only checks can also mutate the checkout. Without this pre-receipt
# check, a clean initial SHA could be reported after tests changed HEAD/files.
# Keep dirty node-only development runs permitted, but never issue release
# evidence for a checkout that changed during execution.
if [[ "$MODE" == node-only && "$COMMIT" != unknown && "$DIRTY" == no ]]; then
  STEP=post-node-checkout-integrity
  if [[ "$(git rev-parse --verify HEAD)" != "$COMMIT" || -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo 'ERROR: Node verification changed the candidate commit or checkout; refusing SHA-bound evidence.' >&2
    exit 2
  fi
  COMPLETED+=("$STEP")
  printf 'PASS: node-only verification preserved the clean candidate checkout and SHA\n' > "$OUT/$STEP.log"
  RECEIPT_STEPS+=("$STEP:1")
fi
if [[ "$MODE" == web || "$MODE" == all ]]; then
  # Always reconcile installed dependencies with the lockfile; an existing
  # node_modules directory is not proof that dependencies match this SHA.
  if [[ "$OFFLINE" == true ]]; then
      run npm-ci-offline npm ci --offline --no-audit --no-fund
    else
      run npm-ci npm ci --prefer-offline --no-audit --no-fund
  fi
  run npm-test npm test
  run npm-typecheck npm run typecheck
  run npm-build npm run build
fi
# A successful build must still correspond to the exact clean source checkout.
# Tests/build tools may rewrite tracked files or change HEAD during execution.
if [[ "$MODE" == web || "$MODE" == all ]]; then
  STEP=post-web-checkout-integrity
  if [[ "$(git rev-parse --verify HEAD)" != "$COMMIT" || -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo 'ERROR: Web verification changed the candidate commit or tracked checkout; results are not release evidence.' >&2
    exit 2
  fi
  COMPLETED+=("$STEP")
  printf 'PASS: clean checkout and expected SHA\n' > "$OUT/$STEP.log"
  RECEIPT_STEPS+=("$STEP:1")
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
  # Native builds can rewrite tracked project settings; refuse stale evidence.
  STEP=post-native-checkout-integrity
  if [[ "$(git rev-parse --verify HEAD)" != "$COMMIT" || -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo 'ERROR: Native verification changed the candidate commit or tracked checkout; results are not release evidence.' >&2
    exit 2
  fi
  COMPLETED+=("$STEP")
  printf 'PASS: clean checkout and expected SHA\n' > "$OUT/$STEP.log"
  RECEIPT_STEPS+=("$STEP:1")
fi
