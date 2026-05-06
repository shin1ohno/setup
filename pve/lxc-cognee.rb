# frozen_string_literal: true
#
# Entry recipe for the cognee LXC (CT 105): Cognee MCP stack via docker compose
# (cognee API + chromadb + qdrant + redis + auth-proxy).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-cognee.rb

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

include_cookbook "lxc-cognee"
# Phase 3a: receiver-side of the centralised auto-apply system. node_exporter
# exposes node + textfile metrics scraped by the monitoring LXC; auto-mitamae
# -target installs the forced-command authorized_keys entry that the
# orchestrator on monitoring (192.168.1.76) uses to push mitamae apply runs.
include_cookbook "node-exporter"
include_cookbook "auto-mitamae-target"
