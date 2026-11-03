#!/usr/bin/env bash
# Run directly on the VM: sudo bash tools/deepseek-agents/oci/install-secret.sh
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
umask 077
read -r -s -p 'Enter DeepSeek API key (hidden): ' api_key
printf '\n'
if [[ ! "${api_key}" =~ ^[A-Za-z0-9_.-]+$ ]] || (( ${#api_key} < 12 )); then
  echo 'Unexpected key format. No file written.' >&2
  exit 1
fi
install -d -m 0700 /etc/mp3-shelf
printf 'DEEPSEEK_API_KEY=%s\n' "${api_key}" > /etc/mp3-shelf/agent.env
chmod 0600 /etc/mp3-shelf/agent.env
unset api_key
echo 'Key saved to /etc/mp3-shelf/agent.env (root only). Never commit or print this file.'
