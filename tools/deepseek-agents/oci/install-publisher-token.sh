#!/usr/bin/env bash
# Separate write-only-for-branches publishing credential. Never expose to OpenCode.
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
umask 077
read -r -s -p 'Fine-grained GitHub PAT (contents+PR write, ONLY mp3-shelf): ' token
printf '\n'
if [[ ! "${token}" =~ ^[A-Za-z0-9_]+$ ]] || (( ${#token} < 25 )); then
  echo 'Token format invalid; no file written' >&2
  exit 1
fi
install -d -m 0700 /etc/mp3-shelf
printf 'GH_TOKEN=%s\n' "${token}" > /etc/mp3-shelf/publisher.env
chmod 0600 /etc/mp3-shelf/publisher.env
unset token
echo 'Publisher token stored root-only. It is never provided to DeepSeek/OpenCode.'
