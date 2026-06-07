# frozen_string_literal: true
#
# Entry recipe for the roon-mcp LXC (CT 108): Roon MCP OAuth-protected server
# fronted by mcp.ohno.be. Connects to lxc-roon at roon-lxc.home.local:9330.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-roon-mcp.rb

include_recipe "../cookbooks/functions/default"

include_cookbook "roon-mcp-server"
lxc_entry(tags: ["lxc", "roon-mcp"])
