# frozen_string_literal: true
#
# lxc-memory (CT 107): OpenMemory MCP server, NATIVE systemd (Python venv).
#
# Phase 0.5-Z Z-2 result determines path:
#   - openmemory-mcp on PyPI runnable as server → use memory-server cookbook (this default)
#   - openmemory only ships docker images → set MEMORY_SERVER_DOCKER_FALLBACK=1
#     in environment, lxc-memory falls back to docker compose via ai-memory cookbook
#
# Bind-mount (set up by Terraform):
#   - /mnt/data/memory (rw, idmap)
#
# RAM 1 GiB (1.2 GiB if docker fallback). CPU 1.

return if node[:platform] == "darwin"

if ENV["MEMORY_SERVER_DOCKER_FALLBACK"] == "1"
  MItamae.logger.warn("lxc-memory: MEMORY_SERVER_DOCKER_FALLBACK=1 — using docker compose path")
  include_cookbook "docker-engine"
  include_cookbook "ai-memory"
else
  include_cookbook "memory-server"
end
