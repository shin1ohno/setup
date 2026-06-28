# es-memory migration + cutover runbook

Parallel-run cutover (old Cognee/Mem0 stay up until ES search quality is
confirmed). Run these from inside the es-memory LXC (or any host with ES + DB
reachability and the env vars set).

## 0. License/capability probes (run FIRST — they gate the design)

dense_vector + kNN are free on a basic license; the RRF retriever may be
gated. The server already falls back to a manual RRF merge, but confirm:

```bash
# kNN on basic license — expect HTTP 200
curl -sk -u "elastic:$ES_PASSWORD" -X POST "$ES_URL/knowledge/_search" \
  -H 'Content-Type: application/json' -d '{
    "knn": {"field":"embedding","query_vector":'"$(python3 -c 'print([0.0]*1536)')"',
            "k":3,"num_candidates":10}}' -o /dev/null -w 'knn=%{http_code}\n'

# RRF retriever — 200 = native RRF, 400/403 = server uses manual fallback
curl -sk -u "elastic:$ES_PASSWORD" -X POST "$ES_URL/knowledge/_search" \
  -H 'Content-Type: application/json' -d '{
    "retriever":{"rrf":{"retrievers":[
      {"standard":{"query":{"match_all":{}}}}]}}}' -o /dev/null -w 'rrf=%{http_code}\n'
```

## 1. Create indices

The MCP server self-bootstraps indices on startup. To create them manually:

```bash
ES_URL=$ES_URL ES_USER=elastic ES_PASSWORD=$ES_PASSWORD \
  bash ../es-indices/setup_indices.sh
```

## 2. Migrate data

```bash
# Mem0 — re-embed ~60-100 memories from the running OpenMemory API
OPENMEMORY_URL=http://127.0.0.1:8765 python3 migrate_mem0.py --dry-run
OPENMEMORY_URL=http://127.0.0.1:8765 python3 migrate_mem0.py

# Cognee — DISCOVERY first (no writes), confirm the table, then --apply
DATABASE_URL=postgresql://cognee:...@<rds-host>:5432/cognee python3 migrate_cognee.py
DATABASE_URL=postgresql://cognee:...@<rds-host>:5432/cognee python3 migrate_cognee.py --apply
```

## 3. Count reconciliation

```bash
curl -sk -u "elastic:$ES_PASSWORD" "$ES_URL/knowledge/_count"
curl -sk -u "elastic:$ES_PASSWORD" "$ES_URL/memory-user/_count"
# compare against Cognee list_data and Mem0 list_memories
```

## 4. A/B search-quality check

Query a representative prompt against the old Cognee `search(CHUNKS)` and the
new ES hybrid; eyeball top-chunk overlap before cutover.

## 5. Cutover (only after quality is acceptable)

Edit `cookbooks/mcp/files/servers.yml`: point the `cognee` and `ai-memory`
`url` at the es-memory endpoints. Re-deploy the `mcp` cookbook. Tool names are
unchanged, so no allowlist edit. Then stop the old stacks:

```bash
# on the cognee LXC (CT105) and memory LXC (CT107)
cd ~/deploy/cognee && docker compose down
cd ~/deploy/memory && docker compose down
```

After both ES migrations are confirmed, the shared Aurora pgvector + Qdrant
can be decommissioned (Terraform in home-monitor).
