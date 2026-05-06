# frozen_string_literal: true
#
# Entry recipe for the weave LXC (CT 109): weave 4-component MQTT mesh
# (mosquitto + roon-hub + weave-server + weave-web). Connects to lxc-roon at
# roon-lxc.home.local:9330 via roon-hub.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-weave.rb

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

include_cookbook "lxc-weave"
# Phase 2: per-host systemd timer (cookbooks/auto-mitamae) is replaced by
# centralised SSH-push from the monitoring LXC's orchestrator. This host
# now installs the orchestrator-side receiver (forced-command in
# authorized_keys + mitamae-runner) and node_exporter for fleet metrics.
# Phase 2b will git rm -r cookbooks/auto-mitamae and the user disables
# the legacy auto-mitamae.timer on this LXC.
include_cookbook "node-exporter"
include_cookbook "auto-mitamae-target"
