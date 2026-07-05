# Elasticsearch gotchas

Load when working with Elasticsearch queries, mappings, `dense_vector`, or kNN. (Kibana-Lens/visualization gotchas live in `~/.claude/docs/kibana-lens.md` — this file is the query/index layer.)

## ES 9.x excludes `dense_vector` from `_source` by default

On Elasticsearch 9.x, a `dense_vector` field is indexed for kNN but **omitted from `_source`** by default. Reading the stored vector back from `_doc._source` returns `None` even though the field exists and kNN works. Any code that reuses a *stored* embedding (a reconcile / dedup loop that fetches a doc's own vector to run kNN, a similarity comparison over `_source.embedding`) silently gets nothing — and typically **reports success while doing nothing useful** (a classic silent failure: "processed N docs", 0 actually adjudicated).

**Detection signature** (all four together = the ES 9.x default, NOT a mapping bug):

- `exists:embedding` count == total docs (the field IS indexed on every doc), AND
- a kNN query returns real hits (the indexed vectors are searchable), AND
- `GET <index>/_doc/<id>` `_source` LACKS the `embedding` field, AND
- `GET <index>/_mapping` shows **no** `_source` excludes and the index is **not** synthetic source (`index.mapping.source.mode` unset).

```bash
curl -s -k -u elastic:$PW "$ES/<index>/_doc/<id>" | jq '._source | has("embedding")'   # false on ES 9.x
curl -s -k -u elastic:$PW "$ES/<index>/_count" -d '{"query":{"exists":{"field":"embedding"}}}'  # == total
```

**Fix**: do not trust a `_source` round-trip for vectors. Re-embed the doc's *content* at point of use to get the query vector (same model / dims / input_type → an equivalent vector), then run kNN. If you genuinely need the stored vector back, set it explicitly and verify empirically — `_source.includes` / `stored_fields` / the `fields` API behavior for `dense_vector` must be *tested*, not assumed to override the 9.x type default.

This is a concrete instance of the "Silent Failure Detection" pattern in `~/.claude/rules/debugging.md` — the unit's success log is not evidence; the ES-side state (was a fact actually adjudicated?) is.

Origin: 2026-07-04 memory-v2 keeper reconcile on ES 9.4.2 — `reconcile.py` read `_source.embedding` for its kNN seed, got `None`, and short-circuited to "no embedding → mark reconciled" for every fact (errors=1, 0 adjudicated) while `exists:embedding`=all and kNN worked. Fixed by re-embedding the fact content.
