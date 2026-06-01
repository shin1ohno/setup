# local-mcp patches — synced copies (keep byte-identical)

These four files are **byte-identical copies** of the cognee / ai-memory
cookbook patches. They are duplicated here (not symlinked / cross-referenced)
because mitamae `remote_file source` is relative to this cookbook's `files/`
dir, and the local-mcp docker-compose mounts them into the container.

| This file | Source of truth | Container mount |
|---|---|---|
| `cognee-mcp-server.py` | `cookbooks/cognee/files/patches/mcp-server.py` | `/app/src/server.py` |
| `cognee-mcp-client.py` | `cookbooks/cognee/files/patches/mcp-cognee-client.py` | `/app/src/cognee_client.py` |
| `openmemory-mcp-server.py` | `cookbooks/ai-memory/files/patches/mcp-server.py` | `/usr/src/openmemory/app/mcp_server.py` |
| `openmemory-database.py` | `cookbooks/ai-memory/files/patches/database.py` | `/usr/src/openmemory/app/database.py` |

## Drift check (must produce NO output)

```bash
diff cookbooks/cognee/files/patches/mcp-server.py        cookbooks/local-mcp/files/patches/cognee-mcp-server.py
diff cookbooks/cognee/files/patches/mcp-cognee-client.py cookbooks/local-mcp/files/patches/cognee-mcp-client.py
diff cookbooks/ai-memory/files/patches/mcp-server.py     cookbooks/local-mcp/files/patches/openmemory-mcp-server.py
diff cookbooks/ai-memory/files/patches/database.py       cookbooks/local-mcp/files/patches/openmemory-database.py
```

When a source patch changes, re-copy here and re-run the drift check. These
patches are Aurora-agnostic (openmemory `database.py` reads `DATABASE_URL`; no
hardcoded remote endpoints), so they work unchanged against the local Postgres.
