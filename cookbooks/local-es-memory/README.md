# local-es-memory

Single-node **ElasticSearch (Docker)** + **memory-v2 MCP** on this MacBook Air.
Replaces the retired `~/deploy/local-mcp` stack (cognee + mem0 + postgres +
qdrant) with the same memory-v2 backend the hosted `es-memory` LXC runs: BM25 +
`dense_vector` kNN hybrid search on ES, Voyage (`voyage-3-large`, 1024-dim)
embeddings. **darwin-only** (`return unless node[:platform] == "darwin"`).

## Architecture

```
Claude Code ──http(loopback)──> 127.0.0.1:8010/memory/mcp  (memory-mcp container)
                                          │ ES_URL=http://es:9200
                                          ▼
                                   es (elasticsearch:9.4.2 + analysis-kuromoji)
                                          127.0.0.1:9200, single-node, security off
```

- **No OIDC/JWT proxy.** Loopback single-user; the LXC's auth-proxy layer is
  omitted. `server.py` derives provenance from `X-Verified-*` headers, so the
  cookbook registers `memory-local` with static `-H` headers
  (`X-Verified-Sub` / `X-Verified-Grant=authorization_code`) — enough to stamp
  provenance and pass destructive-op authz.
- **ES security disabled** (`xpack.security.enabled=false`) — loopback-only bind,
  matching the old local-mcp model. `es_backend` still sends basic auth
  (`elastic:x`); ES ignores it.
- **kuromoji is mandatory**: the memory-v2 indices use the `ja_en_hybrid`
  analyzer (`kuromoji_tokenizer`), so `files/es/Dockerfile` installs
  `analysis-kuromoji` on top of `elasticsearch:9.4.2`.

## Verbatim server copies (do not hand-edit)

`files/mcp/{server,es_backend,voyage,scoring,identity}.py` + `requirements-v2.txt`
are **byte-identical copies** of `cookbooks/lxc-es-memory/files/memory-mcp/`
(+ `files/requirements-v2.txt`). `bin/lint-cookbooks` check 7 enforces equality.
To pick up a server-side change, re-copy from the source and re-run lint:

```sh
src=cookbooks/lxc-es-memory/files
dst=cookbooks/local-es-memory/files/mcp
cp $src/memory-mcp/{server,es_backend,voyage,scoring,identity}.py $dst/
cp $src/requirements-v2.txt $dst/
bin/lint-cookbooks
```

The server self-bootstraps the 4 indices + `memory-all` alias from the inline
`es_backend._INDEX_DEFS` (`ensure_indices()` at import), so no index JSON or
setup script ships here.

## Secrets

`VOYAGE_API_KEY` is fetched from SSM `/memory/voyage-api-key` into
`~/deploy/local-es-memory/.env` by `files/generate_env.sh`, gated on
`require_external_auth` with `--profile default` (the `aws login` identity on
this Mac; `pve-bootstrap-ssm`'s token is stale here). No `elastic-password` —
ES security is off.

## Ops

```sh
cd ~/deploy/local-es-memory
docker compose up -d --build            # cookbook does this via compose_service
docker compose ps
curl -s localhost:9200/_cat/indices?v   # memory-fact/knowledge/episode/stats + memory-all alias
curl -s localhost:9200/_cluster/health  # yellow is normal on a single node
claude mcp list | grep memory-local     # should be Connected
```

**PERSISTENCE**: ES data lives in the `es_data` named volume. `docker compose
down` keeps it; **never `down -v`** (destroys the local memory store).

## Retiring the old local-mcp

`~/deploy/local-mcp` is git-unmanaged. After confirming the new stack:

```sh
cd ~/deploy/local-mcp && docker compose down   # NOT -v — keeps cognee/mem0 volumes for rollback
```

Data migration is a no-op: the old store is effectively empty (mem0 = 0
memories, cognee = 1 test document), so the new ES starts fresh. If real data
ever needs migrating, adapt `cookbooks/lxc-es-memory/files/migrate/migrate_v2.py`
(re-embeds source text with Voyage into the memory-v2 indices).
