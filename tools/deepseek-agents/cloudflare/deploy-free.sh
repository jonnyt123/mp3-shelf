#!/usr/bin/env bash
# Run on Mac with a Cloudflare Workers Free account. No paid tier, no VM.
set -euo pipefail
cd "$(dirname "$0")"
command -v node >/dev/null || { echo 'Node.js is required'; exit 1; }
command -v openssl >/dev/null || { echo 'OpenSSL is required'; exit 1; }
mkdir -p "$HOME/Library/Application Support/MP3ShelfCloudCoordinator"
secret="$HOME/Library/Application Support/MP3ShelfCloudCoordinator/coordinator-token"
umask 077
echo 'Using Cloudflare Workers Free + D1. Never select Workers Paid or add a payment method.'
npm install --no-audit --no-fund
npx wrangler whoami || npx wrangler login
npx wrangler deploy
npx wrangler d1 migrations apply mp3-shelf-agent-jobs --remote
if [[ ! -s "$secret" ]]; then openssl rand -hex 32 > "$secret"; fi
chmod 0600 "$secret"
cat "$secret" | npx wrangler secret put COORDINATOR_TOKEN
echo 'Coordinator deployed, D1 migration applied, and private bearer token installed.'
echo 'Use the workers.dev URL printed by Wrangler when installing the Mac client.'
echo 'Server is PAUSED by default; no DeepSeek model calls have been started.'
