#!/usr/bin/env bash
# One-time OAuth connection to the ALREADY deployed MP3 Shelf Cloudflare Worker.
# No new D1 database, Worker or billing plan. Remains paused.
set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "Mac required" >&2; exit 1; }
cd "$(dirname "$0")"
command -v openssl >/dev/null || { echo "OpenSSL missing" >&2; exit 1; }
command -v node >/dev/null || { echo "Node.js missing" >&2; exit 1; }
root="$HOME/Library/Application Support/MP3ShelfCloudCoordinator"
secret="$root/coordinator-token"
credentials="$root/credentials.json"
mkdir -p "$root"
chmod 0700 "$root"
umask 077
# A rerun should not invalidate an already functioning dashboard token.
if [[ -s "$secret" && -f "$credentials" ]]; then
  if node ./mac-client.mjs --status >/dev/null 2>&1; then
    echo "Cloudflare token already synchronized; preserving the existing dashboard login."
    exit 0
  fi
fi
echo "Authenticating Wrangler with the existing Cloudflare account (interactive browser login may be required)..."
npm install --no-audit --no-fund
if ! npx --no-install wrangler whoami >/dev/null 2>&1; then
  npx --no-install wrangler login
fi
newtoken="$(mktemp "$root/.coordinator-token.XXXXXX")"
trap 'rm -f "$newtoken"' EXIT
openssl rand -hex 32 > "$newtoken"
chmod 0600 "$newtoken"
# Wranger updates the existing deployed Worker secret; it does not change the database.
npx --no-install wrangler secret put COORDINATOR_TOKEN --name mp3-shelf-coordinator < "$newtoken"
mv -f "$newtoken" "$secret"
chmod 0600 "$secret"
trap - EXIT
echo "Cloudflare coordinator connected. The token was rotated and saved locally, not printed."
echo "Dashboard: https://mp3-shelf-coordinator.mp3shelf-jonny.workers.dev/"
