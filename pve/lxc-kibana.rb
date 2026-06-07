# frozen_string_literal: true
#
# Entry recipe for the kibana LXC (CT 115): Kibana 8.x — log analytics UI
# for the 3-node ES cluster.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-kibana.rb

execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl jq"
  not_if "dpkg -s gnupg unzip ca-certificates curl jq >/dev/null 2>&1"
end

include_recipe "../cookbooks/functions/default"

include_cookbook "lxc-kibana"
lxc_entry(tags: ["lxc", "kibana"])
