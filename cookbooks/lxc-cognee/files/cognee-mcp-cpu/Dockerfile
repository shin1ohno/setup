# Build cognee-mcp from the cognee monorepo v1.0.9 tag, pinned to cognee
# 1.0.9, with CPU reductions. Context is the cloned monorepo root (build.sh
# shallow-clones it), so the ./cognee-mcp/* COPY paths resolve.
#
# Why source-build instead of FROM cognee/cognee-mcp:latest:
#   - :latest is NOT version-pinned to cognee; it currently ships cognee
#     1.1.0 (breaking ID->UUID changes we avoid) with a divergent mcp source
#     generation (2008-line server.py) that no longer matches our mounted
#     patches/mcp-*.py (the v1.0.9 generation, 1548-line). Building from the
#     v1.0.9 tag keeps the image's mcp framework + sibling modules in lockstep
#     with the runtime-mounted patches AND the data-plane cognee 1.0.9.
#
# cognee 1.0.9 is force-installed after `uv sync` because the tag's uv.lock
# pins 1.0.4 and the `>=1.0.0,<2.0.0` range would otherwise float to 1.1.0.
#
# Triton (~639MB GPU kernel compiler) is uninstalled — CT 105 has no GPU.
# nvidia-*-cu12 wheels are KEPT: torch 2.7+ _preload_cuda_deps errors at
# import without them even on CPU. The real on-disk win comes from build.sh's
# `docker export | docker import` flatten.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS uv

WORKDIR /app
ENV UV_LINK_MODE=copy

# pg_config (libpq-dev) + toolchain for cognee[postgres-binary] source builds.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Dependencies first (layer caching), then the project.
COPY ./cognee-mcp/pyproject.toml ./cognee-mcp/uv.lock ./cognee-mcp/entrypoint.sh ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev --no-editable

COPY ./cognee-mcp /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-editable

# Force cognee to 1.0.9 to match the data plane exactly (uv.lock pins 1.0.4).
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --python /app/.venv/bin/python \
    "cognee[postgres-binary,docs,neo4j]==1.0.9"

# Drop triton (GPU-only). Keep nvidia-*-cu12 (torch import needs them).
RUN uv pip uninstall --python /app/.venv/bin/python triton || true

# Build-time sanity: torch imports on CPU and cognee is exactly 1.0.9.
# Do NOT import lancedb here — its native ext SIGILLs on this no-AVX2 host;
# API mode + VECTOR_DB_PROVIDER=pgvector keep it out of the runtime path.
RUN /app/.venv/bin/python -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())" \
 && /app/.venv/bin/python -c "import importlib.metadata as m; v=m.version('cognee'); assert v=='1.0.9', 'cognee='+v; print('cognee', v, 'OK')"

FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=uv /usr/local /usr/local
COPY --from=uv /app /app

RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

RUN groupadd --system --gid 1000 cognee \
    && useradd --system --uid 1000 --gid cognee --no-create-home --shell /usr/sbin/nologin cognee \
    && chown -R cognee:cognee /app

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV MCP_LOG_LEVEL=DEBUG
ENV PYTHONPATH=/app

USER cognee
ENTRYPOINT ["/app/entrypoint.sh"]
