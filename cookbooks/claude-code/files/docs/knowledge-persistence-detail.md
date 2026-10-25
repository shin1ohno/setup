Load when a `~/.claude/docs/knowledge-persistence.md` rule points here: memory-mirror internals and config, connector-outage triage, egress probing, memory-v2 tool semantics, or a rule's origin.

# Knowledge Persistence — detail

## retired-cognee-stack

The self-hosted Cognee stack (REST `localhost:8001`, ChromaDB, `docker compose cognee`, `bulk_ingest`, the `~/ingest/drop/` watcher) and its MCP tools (`cognify` / `save_interaction` / cognee `search`) were fully retired. The memory-v2 stack is the single knowledge store.

## memory-mirror-mechanics

harness native のファイル記憶（`~/.claude/projects/<slug>/memory/*.md`）は、`hooks/mirror-file-memory.rb` が MCP ストアへ自動でミラーする。memory ファイルを Write / Edit した時点で PostToolUse hook が該当ファイルだけを送り、SessionStart の `--sweep` が取りこぼし（他ホスト・手編集・hook が lock を取れなかった場合）を回収する。doc_key は `<host>/<project-slug>/<slug>` で upsert されるので、手書きの重複だけが残る。

複製の実害は訂正経路が分かれることです。複製するとファイル側にしか訂正が入らず、ストアには古い主張が残り、`recall` が古い方を高スコアで返します（実測 2026-09-16: 手書き複製が、反証追記入りのファイル正本ミラーより上位に出た）。`revise` は自分が書いた doc しか supersede できません。

含意の補足:

- `ingest` は server 側で `source_class=tool-output` 固定（どのホストから書いても `user-stated` にはならない）。`recall` が「指示として扱ってよい」と教えるのは `user-stated` の `fact` だけ。
- 逆方向（MCP → ファイル）の同期は無い。ファイルを削除すると次の sweep が forget を呼んでミラーも消える。
- hook は書き込みを絶対にブロックせず `exit 0` するが、失敗は `~/.claude/memory-mirror.log` に 1 行残り、同じ内容が agent にも返る（PostToolUse と SessionStart の additionalContext）。ミラー先は `~/.claude/memory-mirror.json` で決まり、この config が無いホストでは hook 自体が no-op。

config は 2 形式ある。

- **work overlay**: `{"server","dataset","enabled"}`。`server` は `~/.claude.json` の `mcpServers` にある http サーバ名（memory-work）で、認証は `headersHelper`。
- **個人ホスト**（pro-dev・mini・neo、`cookbooks/memory-mirror` が配る）: `{"url","auth":{"type":"client_credentials",…},"host","dataset","enabled"}`。Hydra の machine client `memory-mirror` で個人ストア（claude.ai `memory` コネクタと同じ es-memory）へ送る。サーバ側の `CLIENT_POLICY` により、この client ができるのは `file-memory` への ingest と自分の文書の forget だけ。資格情報は `~/.config/memory-mirror/client.env`（0600）で、agent が読む場所ではない。

個人ホストの運用:

- 疎通確認は `ruby ~/.claude/hooks/mirror-file-memory.rb --check`。実トークンで ingest・forget・拒否の 3 系統を往復する。
- SessionStart の sweep（`--sweep --session-start`）には 40 秒の予算と初回一括ガードがある。state が無い状態で 20 件を超えると送らないので、初回だけ手で `--sweep` を実行する。

## connector-timeout-origin

Fallback paths when the connector is down but the endpoint answers: another registered store, curl-MCP for loopback servers, or deferring the write; the connector often recovers within the session. This is the memory/MCP specialization of `rules/debugging.md`'s Noisy Non-Failure Pattern.

Origin: 2026-07-08 — the ai-memory connector timed out for ~40 min while `mcp.ohno.be` answered 401 in 0.06s; writes proceeded via the local store and the connector recovered mid-session.

## egress-probe

Embedding may call external vendor APIs (Voyage, OpenAI, etc.) depending on server config, so self-hosted storage can still egress content to a third party on every write. Probe the embedding config the server process runs with:

```bash
# systemd-managed server (e.g. memory-mcp-v2): endpoints live in the unit's EnvironmentFile
systemctl show <unit> -p Environment -p EnvironmentFiles
sudo grep -iE 'LLM_(PROVIDER|ENDPOINT|MODEL)|EMBEDDING_(PROVIDER|ENDPOINT)|VOYAGE|OPENAI|ANTHROPIC' <env file>
# container-managed server
docker exec <memory-mcp container> env | grep -iE 'LLM_(PROVIDER|ENDPOINT|MODEL)|EMBEDDING_(PROVIDER|ENDPOINT)|VOYAGE|OPENAI|ANTHROPIC'
```

Reading the result: the provider *name* decides nothing. `EMBEDDING_PROVIDER=openai` beside a gateway endpoint means the gateway's OpenAI-compatible API, not OpenAI — and a `VOYAGE_API_KEY` variable name says nothing either, the VALUE may be a gateway key. Probe per deployment: servers get replaced and stores get retired, so a previous deployment's route is not evidence about the current one. For exact-comparison data a local JSON file gives zero egress and an exact diff; the semantic graph adds nothing for fixed numbers.

Origin: 2026-06-19 kpi-delta-monitor loop — `docker exec env` showed `LLM_ENDPOINT=https://api.openai.com/v1`; routing Mercari KPI through it would have egressed to OpenAI. Snapshot moved to a local JSON file.

## memory-v2-tools

The claude.ai `memory` connector serves the unified v2 MCP (ElasticSearch + Voyage embeddings, hybrid BM25 + kNN recall). Retired mem0 names map as: `add_memories` → `remember(type='fact')`, `search_memory` → `recall`, `list_memories` → `browse`.

- `recall(query, type?, top_k?, filters?)` — hybrid search; `type` optionally scopes to `fact` / `knowledge` / `episode`.
- `remember(content, type, tags?)` — `type` MUST be explicit: `fact` (atomic durable fact), `knowledge` (a document/chunk — technical insight, product review, bug root-cause, architectural decision), or `episode` (session summary / light interaction).
- `browse(type?, filters?, sort?, limit?)` + `memory_stats()` — list + counts.
- `ingest(document, dataset, doc_key)` (upsert a whole document), `revise(id, content)`, `forget(id)`, `get(id)`.

Async write model: a write is stored immediately as `raw`, then a keeper (on the es-memory host, `claude -p`) reconciles it (ADD/UPDATE/NOOP dedup) within a tick or two. Transparent to callers — keep saving; a just-written item becomes searchable in its reconciled form shortly after. There is no synchronous extraction step, so no timeout-and-retry dance (this replaces the retired cognify-timeout / `pending-cognify` fallback).

## save-format-origin

Label variants: knowledge notes use Topic / Context (project, stack) / Problem / Solution / Why; reviews Rating / Pros / Cons / Verdict; analyses Findings / Recommendation / Risks. A record holding only facts makes the next reader redo the interpretation from scratch; write the assessment so it can be checked later ("contradicts the measured value", "the denominators are asymmetric"), not as an impression.

Origin: 2026-09-10 — the operator asked for "the facts, the internal interpretation, and your assessment of that interpretation" to be stored together.
