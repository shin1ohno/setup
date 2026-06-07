#!/bin/bash
# Build cognee/cognee-mcp:cpu from the cognee monorepo v1.0.9 tag, pinned to
# cognee 1.0.9, then flatten. See Dockerfile header for the why.
#
# Idempotency: the build is fully pinned (git tag + cognee version), so the
# stamp is a static key — rebuild only when we bump COGNEE_VERSION / MCP_REF
# here, not when an upstream :latest tag drifts.
#
# Flatten rationale: a `docker build`-only image keeps the uv stage's nvidia
# + triton-whiteout layers in the graph. `docker export | docker import`
# collapses to a single live-filesystem layer, which is the actual disk win.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP_FILE="${SCRIPT_DIR}/.last-build-digest"

MCP_REF="v1.0.9"          # cognee monorepo tag (cognee-mcp source generation)
COGNEE_VERSION="1.0.9"    # forced in Dockerfile to match the data plane
BUILD_KEY="${MCP_REF}-cognee-${COGNEE_VERSION}"

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$BUILD_KEY" ] \
   && docker image inspect cognee/cognee-mcp:cpu >/dev/null 2>&1; then
    echo "[build] cognee-mcp:cpu already built from $BUILD_KEY"
    exit 0
fi

echo "[build] Building cognee-mcp:cpu from $BUILD_KEY"

# Shallow-clone the monorepo at the tag; context root must contain ./cognee-mcp.
SRC_DIR="$(mktemp -d)"
trap 'rm -rf "$SRC_DIR"; docker rm "${CID:-}" >/dev/null 2>&1 || true' EXIT
git clone --depth 1 --branch "$MCP_REF" https://github.com/topoteretes/cognee "$SRC_DIR"

docker build -t cognee/cognee-mcp:cpu-tmp -f "${SCRIPT_DIR}/Dockerfile" "$SRC_DIR"

CID=$(docker create cognee/cognee-mcp:cpu-tmp)

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
echo "$BUILD_KEY" > "$STAMP_FILE"

SIZE=$(docker image inspect cognee/cognee-mcp:cpu --format '{{.Size}}')
echo "[build] cognee-mcp:cpu built from $BUILD_KEY. Size: $((SIZE / 1024 / 1024)) MB"
