# memory-v2 MCP server (Voyage embeddings on ES). The 5 modules + requirements
# are copied VERBATIM from cookbooks/lxc-es-memory/files/memory-mcp/ (bin/lint-cookbooks
# enforces byte-equality). No auth-proxy: loopback-only, provenance from static
# X-Verified-* headers set at Claude Code registration.
#
# All deps ship manylinux/musl wheels (mcp / starlette / uvicorn / httpx) — no
# build toolchain needed, so python:3.12-slim is enough on arm64.
FROM python:3.12-slim

WORKDIR /app

COPY requirements-v2.txt .
RUN pip install --no-cache-dir -r requirements-v2.txt

COPY server.py es_backend.py voyage.py scoring.py identity.py ./

EXPOSE 8010

# server.py runs asyncio.run(ensure_indices()) at import (retries 10×3s on cold
# ES), then uvicorn serves the Starlette app mounting the MCP at /memory/mcp.
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8010", "--workers", "1"]
