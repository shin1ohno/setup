#!/bin/bash
# Build cognee/cognee-mcp:cpu by overriding upstream image and flattening.
# Idempotency: only rebuilds when upstream image digest differs from stamp.
#
# A plain `docker build`-only override would NOT reduce on-disk image size:
# the parent image's nvidia/triton layers remain in the image graph even
# after pip uninstall (overlayfs whiteout entries). Flattening via
# `docker export | docker import` collapses everything into one layer with
# only the live filesystem, which is what actually saves disk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP_FILE="${SCRIPT_DIR}/.last-build-digest"

docker pull cognee/cognee-mcp:latest
UPSTREAM_DIGEST=$(docker image inspect cognee/cognee-mcp:latest --format '{{.Id}}')

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$UPSTREAM_DIGEST" ] \
   && docker image inspect cognee/cognee-mcp:cpu >/dev/null 2>&1; then
    echo "[build] cognee-mcp:cpu already built from upstream digest $UPSTREAM_DIGEST"
    exit 0
fi

echo "[build] Building cognee-mcp:cpu from upstream digest $UPSTREAM_DIGEST"

docker build -t cognee/cognee-mcp:cpu-tmp -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"

CID=$(docker create cognee/cognee-mcp:cpu-tmp)
trap 'docker rm "$CID" >/dev/null 2>&1 || true' EXIT

docker export "$CID" | docker import \
    --change 'ENTRYPOINT ["/app/entrypoint.sh"]' \
    --change 'USER cognee' \
    --change 'WORKDIR /app' \
    --change 'ENV PATH=/app/.venv/bin:/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    --change 'ENV LANG=C.UTF-8' \
    --change 'ENV PYTHONUNBUFFERED=1' \
    --change 'ENV MCP_LOG_LEVEL=DEBUG' \
    --change 'ENV PYTHONPATH=/app' \
    --change 'ENV PYTHON_VERSION=3.12.13' \
    - cognee/cognee-mcp:cpu

docker rmi cognee/cognee-mcp:cpu-tmp
echo "$UPSTREAM_DIGEST" > "$STAMP_FILE"

SIZE=$(docker image inspect cognee/cognee-mcp:cpu --format '{{.Size}}')
echo "[build] cognee-mcp:cpu built. Size: $((SIZE / 1024 / 1024)) MB"
