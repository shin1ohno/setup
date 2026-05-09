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

# OpenMemory MCP via docker compose (cookbooks/ai-memory →
# ghcr.io/mem0ai/openmemory-mcp). The native systemd path
# (cookbooks/memory-server) was attempted first but openmemory-mcp on
# PyPI only ships an importable library — no console_scripts entry —
# so systemd ExecStart=/opt/openmemory/venv/bin/openmemory fails with
# status=203/EXEC in a tight restart loop (Phase 0.5-Z Z-2 result).
# Switch the includes below back to memory-server once openmemory-mcp
# ships a CLI binary.
include_cookbook "docker-engine"
include_cookbook "ai-memory"
include_role "lxc-core"

node.reverse_merge!(elastic_agent: { tags: ["lxc", "memory"] })
include_cookbook "elastic-agent"
