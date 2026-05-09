# frozen_string_literal: true
#
# Entry recipe for the es-1 LXC (CT 113): Elasticsearch master+data+ingest
# node, member of the 3-node cluster (es-0/1/2). See pve/lxc-es-0.rb for
# notes — this file differs only in node_name / transport_host.

execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl jq python3"
  not_if "dpkg -s gnupg unzip ca-certificates curl jq python3 >/dev/null 2>&1"
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

node.reverse_merge!(
  elasticsearch: {
    node_name: "es-1",
    transport_host: "192.168.1.78",
  }
)

include_cookbook "lxc-elasticsearch"
include_role "lxc-core"

node.reverse_merge!(elastic_agent: { tags: ["lxc", "elasticsearch", "es-1"] })
include_cookbook "elastic-agent"
