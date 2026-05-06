# frozen_string_literal: true
#
# Entry recipe for the monitoring LXC (CT 111): Prometheus + Grafana fleet
# observability stack + node_exporter + auto-mitamae-target (self-apply).
#
# Phase 2b PR will uncomment auto-mitamae-orchestrator below to take over
# the SSH-push fleet apply role from Phase 1's per-host systemd timers.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-monitoring.rb

# Debian 13 minimal LXC bootstrap (per CLAUDE.md "Debian 13 Minimal LXC —
# Mandatory Bootstrap Packages"). Must precede docker-engine, awscli, and
# any cookbook that uses jq / unzip / gpg dearmor. Idempotent: skip when
# all 5 packages are already installed.
execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl jq"
  not_if "dpkg -s gnupg unzip ca-certificates curl jq >/dev/null 2>&1"
end

include_recipe "../cookbooks/functions/default"

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

# Service LXCs do not include the ssh-keys cookbook — login keys are
# injected at LXC provision time via the home-monitor terraform
# `local.ssh_devices` for_each loop (matches pve/lxc-cognee.rb /
# pve/lxc-weave.rb / pve/lxc-hydra.rb convention). Operator direct SSH
# uses the SSM-stored private key for /ssh-keys/devices/monitoring/private.
include_cookbook "lxc-monitoring"
include_cookbook "node-exporter"
include_cookbook "auto-mitamae-target"
include_cookbook "auto-mitamae-orchestrator"
