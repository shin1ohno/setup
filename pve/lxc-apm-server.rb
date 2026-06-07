# frozen_string_literal: true
#
# Entry recipe for CT 116 apm-server: standalone Elastic APM Server for
# OTLP ingestion from 5 home-fleet services (weave-server, edge-agent,
# roon-mcp, cognee-auth-proxy, ai-memory-auth-proxy). All install +
# config work lives in cookbooks/lxc-apm-server/default.rb.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-apm-server.rb

execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl jq python3"
  not_if "dpkg -s gnupg unzip ca-certificates curl jq python3 >/dev/null 2>&1"
end

include_recipe "../cookbooks/functions/default"

include_cookbook "lxc-apm-server"
