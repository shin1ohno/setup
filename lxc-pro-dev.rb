# frozen_string_literal: true
#
# Entry recipe for the pro-dev LXC (CT 104): personal SSH workspace
# continuation of bare-metal `pro` — re-applies the linux.rb role set so
# `ssh pro-dev` retains the same ergonomics (profile.d, fzf, mise, etc.)
# that the legacy host had.
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

include_cookbook "lxc-pro-dev"
