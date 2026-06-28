# es-memory-mcp — unified Cognee+Mem0 MCP server backed by ElasticSearch.
# Classic builder compatible (no BuildKit-only syntax) for unprivileged
# PVE LXC builds with DOCKER_BUILDKIT=0 — see ~/.claude/rules/pve-lxc.md.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY es_backend.py /app/es_backend.py
COPY server.py /app/server.py

EXPOSE 8000

# Healthcheck hits the cognee namespace's MCP endpoint liveness (any HTTP
# response means the app is up; MCP returns 4xx for a bare GET which is fine).
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/cognee/mcp', timeout=5)" || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
