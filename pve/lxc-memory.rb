# frozen_string_literal: true
#
# Entry recipe for the memory LXC (CT 107): OpenMemory MCP server (native
# Python venv by default; set MEMORY_SERVER_DOCKER_FALLBACK=1 to switch to
# the docker compose path via cookbooks/ai-memory).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-memory.rb

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

# Force docker fallback. The native systemd path expects
# `pip install openmemory-mcp` to ship an `openmemory` CLI binary at
# `venv/bin/openmemory`, but the published PyPI package only provides
# the library (`import openmemory_mcp`) — no console_scripts entry
# point. systemd's `ExecStart=/opt/openmemory/venv/bin/openmemory
# serve …` fails with `status=203/EXEC` in a tight restart loop.
# The docker variant (cookbooks/ai-memory + ghcr.io/mem0ai/openmemory-mcp)
# is the only working topology today (Phase 0.5-Z Z-2 result).
# Drop this override once openmemory-mcp ships a CLI binary.
ENV["MEMORY_SERVER_DOCKER_FALLBACK"] = "1"

include_cookbook "lxc-memory"
# Phase 3a: receiver-side of the centralised auto-apply system. node_exporter
# exposes node + textfile metrics scraped by the monitoring LXC; auto-mitamae
# -target installs the forced-command authorized_keys entry that the
# orchestrator on monitoring (192.168.1.76) uses to push mitamae apply runs.
include_cookbook "node-exporter"
include_cookbook "auto-mitamae-target"
