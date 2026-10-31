#!/usr/bin/env bash
# Connect to the preprovisioned MP3 Shelf Cloudflare Worker.
# Replaces the temporary server-only token with a fresh locally generated one.
set -euo pipefail
cd "$(dirname "$0")"
command -v openssl >/dev/null || exit 1
command -v node >/dev/null || exit 1
npm install --no-audit --no-fund
npx wrangler whoami || npx wrangler login
secret="$HOME/Library/Application Support/MP3ShelfCloudCoordinator/coordinator-token"
mkdir -p "$(dirname "$secret")"
umask 077
# Rotate on every new Mac connection so no previous bearer token remains useful.
openssl rand -hex 32 > "$secret"
chmod 0600 "$secret"
cat "$secret" | npx wrangler secret put COORDINATOR_TOKEN --name mp3-shelf-coordinator
echo "Fresh token synchronized to the already deployed Worker. No database recreation or paid plan."
echo "Worker URL: https://mp3-shelf-coordinator.mp3shelf-jonny.workers.dev"
