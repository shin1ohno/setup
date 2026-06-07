# frozen_string_literal: true
#
# Entry recipe for CT 117 praeco: PoC of praeco (ElastAlert 2 GUI) on a
# dedicated LXC. Standalone Vue.js SPA + Python elastalert-server stack.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-praeco.rb

execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl jq"
  not_if "dpkg -s gnupg unzip ca-certificates curl jq >/dev/null 2>&1"
end

include_recipe "../cookbooks/functions/default"

include_cookbook "lxc-praeco"
lxc_entry(tags: ["lxc", "praeco"])
