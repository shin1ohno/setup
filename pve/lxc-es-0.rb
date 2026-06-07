# frozen_string_literal: true
#
# Entry recipe for the es-0 LXC (CT 112): Elasticsearch master+data+ingest
# node, member of the 3-node cluster (es-0/1/2).
#
# Per-node attributes set here; the lxc-elasticsearch cookbook is shared
# across the three CTs and reads NODE_NAME / TRANSPORT_HOST from
# node[:elasticsearch].
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-es-0.rb

execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl jq python3"
  not_if "dpkg -s gnupg unzip ca-certificates curl jq python3 >/dev/null 2>&1"
end

include_recipe "../cookbooks/functions/default"

# transport_host == this node's own LAN IP, resolved once by
# cookbooks/host-profile from its offline FLEET table (canonical source:
# home-monitor contracts/devices.json). Fail fast if the hostname didn't
# match a FLEET es-* entry rather than binding ES transport to nil.
es_ip = node[:profile][:ip]
raise "lxc-es-0: node[:profile][:ip] nil for hostname '#{node[:profile][:hostname]}' — add an es-0 entry to cookbooks/host-profile FLEET" unless es_ip
node.reverse_merge!(
  elasticsearch: {
    node_name: "es-0",
    transport_host: es_ip,
  }
)

include_cookbook "lxc-elasticsearch"
# enable_es_node_monitoring_integration: this node's elastic-agent collects
# its OWN node + node_stats (scope: node) for Kibana Stack Monitoring. The
# cluster-level ES metricsets + Kibana are collected centrally on CT 111.
lxc_entry(
  tags: ["lxc", "elasticsearch", "es-0"],
  elastic_agent_extra: { enable_es_node_monitoring_integration: true },
)
