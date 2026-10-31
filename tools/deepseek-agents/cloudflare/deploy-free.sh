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
# Wrangler requires the real D1 UUID. Create the FREE D1 database before deploying.
# An existing database with no configured UUID is an explicit stop (never create duplicates).
node -e '
const fs=require("fs");const c=JSON.parse(fs.readFileSync("wrangler.jsonc","utf8"));
if(c.d1_databases?.some(x=>x.database_id))process.exit(0);
process.exit(2);
' || {
  echo 'Creating the D1 Free database. If it already exists, stop and recover its UUID instead.'
  npx wrangler d1 create mp3-shelf-agent-jobs --binding DB --update-config
}
# Wrangler may append a second binding; pin exactly the new database with a UUID.
node - <<'JS'
const fs=require("fs"),p="wrangler.jsonc";
const cfg=JSON.parse(fs.readFileSync(p,"utf8"));
const match=cfg.d1_databases?.filter(x=>x.binding==="DB"&&x.database_name==="mp3-shelf-agent-jobs"&&
  /^[0-9a-f-]{36}$/i.test(x.database_id||""));
if(!match?.length)throw Error("No valid D1 UUID in Wrangler config; deployment blocked");
cfg.d1_databases=[{...match[match.length-1],migrations_dir:"migrations"}];
fs.writeFileSync(p,JSON.stringify(cfg,null,2)+"\n");
JS
npx wrangler d1 migrations apply mp3-shelf-agent-jobs --remote
npx wrangler deploy
if [[ ! -s "$secret" ]]; then openssl rand -hex 32 > "$secret"; fi
chmod 0600 "$secret"
cat "$secret" | npx wrangler secret put COORDINATOR_TOKEN
echo 'Coordinator deployed, D1 migration applied, and private bearer token installed.'
echo 'Use the workers.dev URL printed by Wrangler when installing the Mac client.'
echo 'Server is PAUSED by default; no DeepSeek model calls have been started.'
