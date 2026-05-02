#!/usr/bin/env bash
# Install Tailscale on Debian 13 (Trixie) — used by PVE host for break-glass
# rescue access. Mirrors cookbooks/tailscale/files/install.sh but pinned to
# trixie repo (PVE 9 base).
set -euo pipefail

if command -v tailscale >/dev/null 2>&1; then
  echo "tailscale already installed: $(tailscale --version | head -1)"
  exit 0
fi

# Repo signing key + apt source (Debian 13 = trixie)
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg

curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list

apt-get update -qq
apt-get install -y -qq --no-install-recommends tailscale

# Enable but DO NOT auto-`tailscale up` — break-glass auth happens by
# operator post-bootstrap via tag:emergency-admin.
systemctl enable --now tailscaled

echo "tailscale installed: $(tailscale --version | head -1)"
echo "Next: sudo tailscale up --advertise-tags=tag:emergency-admin --hostname=pve --ssh"
