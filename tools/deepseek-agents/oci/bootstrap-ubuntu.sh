#!/usr/bin/env bash
# Execute on a new Oracle Always Free Ubuntu 24.04 ARM VM as root.
# DOES NOT request/create VM resources, add billable services, or install API credentials.
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
if [[ "$(uname -s)" != 'Linux' ]]; then echo 'Linux required' >&2; exit 1; fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git gh
tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT
curl -fLsS https://deb.nodesource.com/setup_22.x -o "${tmp}"
# Official NodeSource package setup. Review before running on your VM.
bash "${tmp}"
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
node --version
npm install --global @opencode/cli@2
getent group mp3share >/dev/null || groupadd --system mp3share
id -u mp3agent >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/mp3agent --shell /usr/sbin/nologin mp3agent
id -u mp3publisher >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/mp3publisher --shell /usr/sbin/nologin mp3publisher
usermod -aG mp3share mp3agent
usermod -aG mp3share mp3publisher
install -d -o mp3agent -g mp3share -m 2750 /srv/mp3-shelf /srv/mp3-shelf-agent-worktrees /srv/.mp3-shelf-agent-state
install -d -o mp3agent -g mp3share -m 2750 /srv/.mp3-shelf-agent-state/approved
install -d -o mp3publisher -g mp3publisher -m 0700 /var/lib/mp3publisher
if [[ ! -d /srv/mp3-shelf/.git ]]; then
  runuser -u mp3agent -- git clone --single-branch --branch agent/mp3-deepseek-low-cost-worker https://github.com/jonnyt123/mp3-shelf.git /srv/mp3-shelf
else
  echo 'Using existing /srv/mp3-shelf; not resetting or updating it'
fi
# Share read-only Git objects and approvals, not API keys, with the separate publisher.
chgrp -R mp3share /srv/mp3-shelf
chmod -R g+rX /srv/mp3-shelf
find /srv/mp3-shelf -type d -exec chmod g+s {} +
runuser -u mp3agent -- npm ci --prefix /srv/mp3-shelf --ignore-scripts
install -d -o root -g root -m 0755 /opt/mp3-shelf-publisher
install -m 0644 /srv/mp3-shelf/tools/deepseek-agents/publish.mjs /opt/mp3-shelf-publisher/publish.mjs
install -m 0644 /srv/mp3-shelf/tools/deepseek-agents/oci/mp3-shelf-publisher.service /etc/systemd/system/mp3-shelf-publisher.service
install -m 0644 /srv/mp3-shelf/tools/deepseek-agents/oci/mp3-shelf-publisher.path /etc/systemd/system/mp3-shelf-publisher.path
install -d -o root -g root -m 0700 /etc/mp3-shelf
install -m 0644 /srv/mp3-shelf/tools/deepseek-agents/oci/mp3-shelf-agent.service /etc/systemd/system/mp3-shelf-agent.service
systemctl daemon-reload
echo 'Installed. Neither worker nor publishing broker enabled. Configure separate API/PAT secrets, verify real balances and test, then enable services explicitly.'
