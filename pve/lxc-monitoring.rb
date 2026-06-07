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

# Service LXCs do not include the ssh-keys cookbook — login keys are
# injected at LXC provision time via the home-monitor terraform
# `local.ssh_devices` for_each loop (matches pve/lxc-cognee.rb /
# pve/lxc-weave.rb / pve/lxc-hydra.rb convention). Operator direct SSH
# uses the SSM-stored private key for /ssh-keys/devices/monitoring/private.
include_cookbook "lxc-monitoring"
lxc_entry(tags: ["lxc", "monitoring"], elastic_agent_extra: {
  # Enable Prometheus federation input — CT 111 is the only host in the
  # fleet running Prometheus, so this is the only LXC where the
  # `prometheus/collector` integration makes sense. Streams U/V/W
  # (Kibana dashboards: RTX Routers, Auto-mitamae Fleet, Proxmox via
  # Prometheus) consume the resulting metrics-prometheus.collector-default
  # data stream.
  enable_prometheus_integration: true,
  # Enable Synthetics integration — centralized probe-host topology.
  # CT 111 probes 14 LXC service endpoints (HTTP + TCP) and feeds the
  # synthetics-* indices, which back the Kibana Observability Uptime
  # app. See cookbooks/elastic-agent/files/elastic-agent.synthetics-input.yml
  # for the endpoint inventory.
  enable_synthetics_integration: true,
  # Enable Stack Monitoring collection — CT 111 runs a single standalone
  # agent that collects ES + Kibana stack-monitoring metrics over the
  # network (es-0/1/2:9200, kibana:5601) into the
  # metrics-{elasticsearch,kibana}.stack_monitoring.* data streams that
  # back Kibana's Stack Monitoring UI. Pairs with monitoring.ui.ccs.enabled:
  # false in lxc-kibana's kibana.yml. See
  # cookbooks/elastic-agent/files/elastic-agent.stack-monitoring-input.yml.
  enable_stack_monitoring_integration: true,
})

# auto-mitamae-orchestrator drives the SSH-push fleet apply. It writes
# auto-mitamae.prom into node-exporter's textfile dir (created by lxc-core
# via lxc_entry), so it must run AFTER lxc_entry.
include_cookbook "auto-mitamae-orchestrator"
