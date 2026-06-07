# frozen_string_literal: true
#
# Entry recipe for the es-2 LXC (CT 114): Elasticsearch master+data+ingest
# node, member of the 3-node cluster (es-0/1/2). See pve/lxc-es-0.rb for
# notes — this file differs only in node_name / transport_host.

execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl jq python3"
  not_if "dpkg -s gnupg unzip ca-certificates curl jq python3 >/dev/null 2>&1"
end

include_recipe "../cookbooks/functions/default"

node.reverse_merge!(
  elasticsearch: {
    node_name: "es-2",
    transport_host: "192.168.1.79",
  }
)

include_cookbook "lxc-elasticsearch"
lxc_entry(tags: ["lxc", "elasticsearch", "es-2"])
