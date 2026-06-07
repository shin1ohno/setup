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

include_cookbook "docker-engine"
include_cookbook "lxc-cognee"
lxc_entry(tags: ["lxc", "cognee"])
