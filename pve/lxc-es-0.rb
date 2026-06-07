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

node.reverse_merge!(
  elasticsearch: {
    node_name: "es-0",
    transport_host: "192.168.1.77",
  }
)

include_cookbook "lxc-elasticsearch"
lxc_entry(tags: ["lxc", "elasticsearch", "es-0"])
