# frozen_string_literal: true
#
# lxc-cognee (CT 105): Cognee MCP stack via Docker Compose.
#
# Bind-mount (set up by Terraform):
#   - /mnt/data/cognee (rw, idmap)
#
# RAM 8 GiB / CPU 4. Includes:
#   - cognee API
#   - chromadb (vector store)
#   - qdrant (alt vector store, used by some flows)
#   - redis (cache)
#   - cognee-watcher (drop-folder ingest)
#   - auth-proxy (Hydra JWT validation in front of cognee API)

return if node[:platform] == "darwin"

include_cookbook "docker-engine"
include_cookbook "cognee"
