# frozen_string_literal: true
#
# Entry recipe for the pro-dev LXC (CT 104): personal SSH workspace
# continuation of bare-metal `pro` — re-applies the linux.rb role set so
# `ssh pro-dev` retains the same ergonomics (profile.d, fzf, mise, etc.)
# that the legacy host had.
#
# Bind-mounts (set up by Terraform):
#   - /mnt/data/workspace (rw, idmap)
#   - /mnt/Media (ro, optional)
#
# Networking: vmbr1, independent tailscaled (Magic DNS = pro-dev,
# tag:dev-host). Separate from pro-router LXC's tailscaled to give barrier
# isolation — pro-router upgrade failure does not kill personal SSH access.
#
# RAM 12 GiB / CPU 6 / rootfs 200 GiB.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local lxc-pro-dev.rb
#
# Phase 4 follow-up: ManagedProjects rsync, AWS profile, GPG keys are
# restored from /mnt/data/pve-migration-backup-* via host bind-mount.

include_recipe "cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

# pro-dev specifics. Skip ollama (CPU-only LXC, install.sh 404s, no local
# LLM runtime in scope). Pin tailscale identity to /tailscale/pro-dev-auth-key.
node.reverse_merge!(
  llm: { skip_ollama: true },
  lxc_dev: {
    hostname: "pro-dev",
    tailscale_tag: "tag:dev-host",
    tailscale_ssm_key: "/tailscale/pro-dev-auth-key",
  },
)

include_cookbook "lxc-dev-workstation"
