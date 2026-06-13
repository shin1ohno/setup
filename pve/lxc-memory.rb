# frozen_string_literal: true
#
# Entry recipe for the memory LXC (CT 107): OpenMemory MCP server (native
# Python venv by default; set MEMORY_SERVER_DOCKER_FALLBACK=1 to switch to
# the docker compose path via cookbooks/lxc-memory).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-memory.rb

include_recipe "../cookbooks/functions/default"

# OpenMemory MCP via docker compose (cookbooks/lxc-memory →
# ghcr.io/mem0ai/openmemory-mcp). A native systemd/venv path was attempted
# first but openmemory-mcp on PyPI only ships an importable library — no
# console_scripts entry — so a systemd ExecStart fails with status=203/EXEC
# in a tight restart loop (Phase 0.5-Z Z-2 result). The docker image bundles
# a working entrypoint.
include_cookbook "docker-engine"
include_cookbook "lxc-memory"
lxc_entry(tags: ["lxc", "memory"])
