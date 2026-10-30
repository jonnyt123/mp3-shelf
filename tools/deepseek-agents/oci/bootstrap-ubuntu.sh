#!/usr/bin/env bash
# Execute on a new Oracle Always Free Ubuntu 24.04 ARM VM as root.
# DOES NOT request/create VM resources, add billable services, or install API credentials.
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
if [[ "$(uname -s)" != 'Linux' ]]; then echo 'Linux required' >&2; exit 1; fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git
tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT
curl -fLsS https://deb.nodesource.com/setup_22.x -o "${tmp}"
# Official NodeSource package setup. Review before running on your VM.
bash "${tmp}"
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
node --version
npm install --global @opencode/cli@2
id -u mp3agent >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/mp3agent --shell /usr/sbin/nologin mp3agent
install -d -o mp3agent -g mp3agent -m 0750 /srv/mp3-shelf /srv/mp3-shelf-agent-worktrees /srv/.mp3-shelf-agent-state
if [[ ! -d /srv/mp3-shelf/.git ]]; then
  runuser -u mp3agent -- git clone --single-branch --branch agent/mp3-deepseek-low-cost-worker https://github.com/jonnyt123/mp3-shelf.git /srv/mp3-shelf
else
  echo 'Using existing /srv/mp3-shelf; not resetting or updating it'
fi
install -d -o root -g root -m 0700 /etc/mp3-shelf
install -m 0644 /srv/mp3-shelf/tools/deepseek-agents/oci/mp3-shelf-agent.service /etc/systemd/system/mp3-shelf-agent.service
systemctl daemon-reload
echo 'Installed. The service is NOT enabled/started. Configure the secret at /etc/mp3-shelf/agent.env, verify a positive API balance, then explicitly enable/start it.'
