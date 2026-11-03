#!/usr/bin/env bash
# Performs an account balance check and offline guard tests, then enables the Linux service.
# Only run after provisioning an Always Free VM and installing the key outside GitHub.
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
if [[ ! -r /etc/mp3-shelf/agent.env ]]; then echo 'DeepSeek secret file missing' >&2; exit 1; fi
set -a
# install-secret.sh only accepts ASCII alphanumerics, dot, underscore and hyphen.
source /etc/mp3-shelf/agent.env
set +a
if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then echo 'DEEPSEEK_API_KEY missing' >&2; exit 1; fi
export HOME=/var/lib/mp3agent
cd /srv/mp3-shelf
echo 'Checking local worker logic (no paid model calls)...'
runuser -u mp3agent --preserve-environment -- node --test tools/deepseek-agents/runner.test.mjs
echo 'Checking actual DeepSeek balance (read-only)...'
status_json=$(runuser -u mp3agent --preserve-environment -- node tools/deepseek-agents/runner.mjs --status)
printf '%s\n' "${status_json}" | node -e '
let input="";
process.stdin.on("data",c=>input+=c);
process.stdin.on("end",()=>{
 const s=JSON.parse(input);
 const min=Number(process.env.MP3_AGENT_MIN_BALANCE||0.25);
 if(!Number.isFinite(s.balance?.amount)||s.balance.amount<min) {
  console.error("Available API balance below minimum. Service not enabled.");
  process.exitCode=1;
 } else {
  console.log("DeepSeek balance verified: "+s.balance.amount+" "+s.balance.currency);
  console.log("Next agent: "+s.nextAgent);
 }
});
'
unset DEEPSEEK_API_KEY
echo 'Installing and starting independent agent service...'
systemctl enable --now mp3-shelf-agent
systemctl --no-pager --full status mp3-shelf-agent | sed -n '1,14p'
echo 'Service activated. Local commits remain isolated and are NOT pushed to GitHub until a separate safe publishing flow is configured.'
