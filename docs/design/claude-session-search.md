# Claude Code session search and resume — design spec

**Status**: Draft for review. The shared contracts in §7 need explicit agreement before any implementation starts.
**Scope**: Search Claude Code session transcripts across projects and hosts, and resume a hit with one key. Nothing else.
**Home**: This file lives in `setup` for now and moves to `shin1ohno/ai-memory` with the rest of the memory-v2 code under ADR 0013.

## 1. Summary

Session transcripts are ingested into the memory-v2 Elasticsearch already deployed in each trust boundary, and an fzf picker searches them through the existing authenticated memory-v2 server and resumes a hit with `cd <cwd> && claude --resume <id>`. Each boundary is searched only from its own hosts: the work boundary uses memory-work on sh1-cloud, and the personal boundary uses the es-0/1/2 cluster behind CT 119.

Every byte that leaves a host is masked first: ES documents, embedding input, and the session archive. The archive is a masked copy of each main JSONL, kept in object storage for one year so that a session can be resumed from a different host, or after Claude Code's 30-day cleanup has removed the local file.

The headline numbers below come from 33 days of real transcripts on sh1-cloud (§3).

| Metric | Value |
|---|---|
| Message docs | ≈ 68k per host per 30 days |
| Search index | ≈ 0.63 GB per host per year |
| Archive | ≈ 0.94 GB per host per year |
| Lexical query, session-grouped, server-side | p95 20 ms |

## 2. Goals and non-goals

**Goals**

1. Search the full text of user and assistant messages in every project on every host in the boundary. `--deep` extends the search to tool inputs and outputs.
2. Resume a selected session with one key, from any host in the boundary, for up to one year.
3. Make the lexical path fast enough to re-query on every keystroke: end-to-end p95 under 100 ms on the ES host.
4. Keep the picker usable when the server is unreachable, with a local, degraded fallback.
5. Never let an unmasked secret leave the originating host.

**Non-goals**

- Replacing the JSONL. Claude Code's own files stay the source of truth while they exist.
- Analytics, dashboards, cost reporting, or summarising sessions.
- Searching across the work/personal boundary.
- Editing, merging, or rewriting sessions. The only exception is the `--fork-session` pass-through.
- Feeding transcripts into `recall`. The new indices are excluded from the `memory-all` alias.

## 3. Measured baseline

Source: `~/.claude/projects` on sh1-cloud, 2026-10-06. The window is 33 days (oldest file 2026-09-03), which matches the default `cleanupPeriodDays` of 30. The scripts that produced these numbers are reproduced in Appendix A.

### 3.1 Corpus composition

| Item | Value |
|---|---|
| JSONL files | 1,258 (209 main sessions, 1,049 subagent transcripts) |
| Bytes | 1,217 MB (main 254 MB, subagents 963 MB) |
| Bytes by record type | `attachment` 679 MB (56%), `user` 284 MB, `assistant` 237 MB, all others < 20 MB |
| `tool_result` text | 167 MB = 13.7% of all bytes. Lines that contain a tool_result make up 22% of bytes. |
| `tool_result` size per block (34,010 blocks) | p50 1,643 B · p95 23,645 B · p99 40,232 B · max 87,893 B |
| Text blocks, excluding thinking | 17.7 MB |
| user/assistant records | 95,680. 7,284 of them carry text (main 4,034, subagent 3,241). |
| Docs indexed when tool parts are included | 75,351 |
| Text messages per main session | p50 3 · p95 78 · max 516 |
| `entrypoint` of main sessions | `sdk-cli` 81 · `sdk-py` 80 · `cli` 27 · `claude-desktop` 15 · unset 6 |
| `tool-results/` side files | 117 MB across 51 sessions |

What follows from these numbers:

- `attachment` records are injected context: hook output, CLAUDE.md instructions, memory files, tool listings. They are 56% of the bytes and appear in every file. A raw `rg` for `worktree` matched 1,223 of 1,258 files, so unstructured grep has almost no precision.
- 161 of 209 main sessions are headless (`sdk-*`) loop runs. The picker hides them by default.
- Text is small (17.7 MB). Tool output dominates the index size as soon as it is included.

### 3.2 Index size by tool_text cap N

Measured on ES 9.4.2 with kuromoji, `best_compression`, one shard, no replica, and force-merged to one segment.

| Variant | Docs | Store | Per host per year (scaled by 365/33) |
|---|---|---|---|
| text only | 7,284 | 11.1 MB | 0.12 GB |
| + tool_text, N = 1 KB | 75,351 | 44.2 MB | 0.49 GB |
| + tool_text, N = 2 KB | 75,351 | 56.8 MB | 0.63 GB |
| + tool_text, N = 4 KB | 75,351 | 75.0 MB | 0.83 GB |
| N = 2 KB + bigram subfield on text | 75,352 | 71.7 MB | 0.79 GB |

The share of tool_results truncated by the cap is 58% at 1 KB, 46% at 2 KB and 32% at 4 KB.

**Decision: N = 2 KB, split as the first 1,536 B plus the last 512 B of each tool_result.** The same cap applies to each serialized tool_use input. Going from 1 KB to 2 KB costs 12.6 MB per 33 days and fully covers 12 more points of results. Going from 2 KB to 4 KB costs 18.2 MB for 14 more points. Errors such as stack traces, test failures and exit codes tend to sit at the end of the output, which is why the tail is kept.

The bigram subfield is not in v1: it adds 26% to the index and 39% to p95 (§3.3).

### 3.3 Query latency: highlighting is the cost

Index variant v_n2k, 20 mixed Japanese and English queries × 5 runs, warm, loopback.

| Query shape | p50 | p95 |
|---|---|---|
| `collapse` on session, no highlight, size 50 | 16 ms | 20 ms |
| `terms` aggregation on session (max score) | 6 ms | 8 ms |
| `collapse` + `inner_hits` highlight | 41–50 ms | 99–111 ms |
| `collapse` + top-level highlight | 57 ms | 208 ms |
| plain `size: 200`, client-side grouping | 53 ms | 78 ms |

Highlighting is what costs time, so the keystroke path never highlights. Snippets come only from the preview call, which is scoped to a single session (§6.7).

### 3.4 Archive size

| Input | Raw | gzip -6 | zstd -3 |
|---|---|---|---|
| main JSONL | 267 MB | 66 MB | 38.7 MB |
| `tool-results/` | 117 MB | 51 MB | 46.2 MB |
| main + tool-results, per host per year | 4.2 GB | 1.29 GB | 0.94 GB |

Subagent transcripts are not archived (§6.5); they would add about 1.9 GB per host per year compressed.

### 3.5 Fallback (ripgrep) timing

`rg -l -F -i` over all 1.2 GB takes 0.08–0.39 s. Restricted to main files (254 MB) it takes 0.04 s. Both figures are warm cache. Parsing every file in Python takes 65 s wall clock for the whole corpus, so the fallback parses only the files that rg pre-selects (§6.8).

## 4. Decisions

| ID | Topic | Decision |
|---|---|---|
| A | Tool output | Hybrid. `tool_text` (tool_use input plus tool_result, capped as in §3.2) is a separate field. It is searched only with `--deep` and boosted 0.5 against `text` at 2.0. |
| B | Hit whose JSONL is not on this host | Download the masked archive from the store, restore it locally, then resume. With no archive, the hit is view-only. |
| C | Retention | Masked main JSONL plus `tool-results/` are archived to object storage: GCS for work, S3 for personal. ES and the archive keep a session for 365 days after its last update. Local JSONL keeps Claude Code's `cleanupPeriodDays` (30). |
| D | Semantic search | In v1, as message-level kNN on `text`, fused with BM25 by client-side RRF (k = 60, the existing `scoring.rrf_fuse`). It is off the keystroke path (§6.7). |
| E | Masking | Prefixed API keys and tokens, private-key blocks, and `.env`/config-style secret values. A match is replaced with `[REDACTED:<kind>:<hmac8>]`. Masking runs on the client before anything leaves the host, and the server re-scans every record. |
| F | Boundary | Work hosts (air, sh1-cloud) use only memory-work. Personal hosts (pro-dev, mini, neo) use only the personal store. The server rejects ingest from a host label that is not on its allowlist. |
| G | Access path | Clients never talk to ES directly. Every call goes through the memory-v2 server's new `/memory/sessions/v1/*` routes behind the existing auth proxy. The work ES is loopback-bound and the personal ES is LAN-only, so a direct path does not exist from air anyway. |
| H | Parsing location | The server parses. A client only diffs, masks, and ships raw (masked) lines. As a result, one parser exists, and the whole index can be rebuilt from the archive without any client. |

The original "ingest → ES; picker → ES" sketch changed in four places: ES access (G), parsing location (H), archive and resume (B, C), and boundary separation (F). The hook and backfill triggers stay, and a periodic sweep is added (§6.4) because `SessionEnd` never fires on kill or crash.

Standard-mechanism check:

- **Search**: a single-host picker could use SQLite FTS5 (the claude-recall approach) with no server at all. ES is chosen for three reasons: cross-host search inside a boundary, one-year retention beyond the local 30-day cleanup, and the snapshot and auth already in place. Without those requirements ES would be the wrong tool.
- **Archive**: the archive uses each platform's standard object store and lifecycle rules. It does not keep blobs in ES.

## 5. Architecture

```
 originating host (any host in the boundary)                    ES host (CT 119 / sh1-cloud)
 ┌───────────────────────────────────────────┐   HTTPS/tailnet  ┌──────────────────────────────────────┐
 │ Claude Code ──Stop/SessionEnd──► C4 hook  │                  │ auth proxy (existing, unchanged)     │
 │                                  (Ruby)   │                  │   │ /memory/*                        │
 │ timer (15 min) ────────────────► C3 ccs   │                  │   ▼                                  │
 │                         ingest/sweep      │  POST ingest     │ memory-mcp (existing process)        │
 │   ~/.claude/projects/**.jsonl ──► diff    │ ───────────────► │   └─ C6 sessions app  /sessions/v1/* │
 │                                 ► C2 mask │                  │        ├─ C1 parse ─► ES indices      │
 │                                 ► ship    │                  │        ├─ C2 re-scan                  │
 │                                           │  POST search     │        ├─ embed (existing voyage.py) │
 │ user ──► C7 picker (fzf) ──────────────── │ ───────────────► │        └─ archive ─► GCS / S3         │
 │            │ Enter                         │  GET archive     │ C8 retention timer                   │
 │            ▼                               │ ◄─────────────── │                                      │
 │  cd <cwd> && exec claude --resume <id>    │                  └──────────────────────────────────────┘
 │  (offline: C9 rg fallback, local only)    │
 └───────────────────────────────────────────┘
```

## 6. Components

Each component is described with the same four headings: responsibility, inputs and outputs, and how it relates to existing modules.

### 6.1 C1 `sessions.parse` — transcript parser (server, Python)

- **Responsibility**: turn raw masked JSONL lines into message docs and a session-doc delta. It is lenient by design: an unknown record or block type is counted and skipped, never raised.
- **Input**: `(session_key, kind, lines[], start_offset)`.
- **Output**: a list of message docs (§7.1.2), a session update (§7.1.1), and counters such as `unknown_types{}` and `skipped_noise`.
- **Rules**:
  - Records are indexed only when `type ∈ {user, assistant}`. `isMeta: true` and `isCompactSummary: true` are skipped.
  - `text` = the `text` blocks plus string `content`. Leading blocks are stripped first: `<system-reminder>`, `<command-name>`, `<command-message>`, `<command-args>`, `<local-command-stdout>`, `<local-command-stderr>`, `<task-notification>`, `<bash-stdout>`, `<bash-stderr>`. `thinking` is never indexed.
  - `tool_text` = for each `tool_use`, `name` plus the input fields `command | file_path | path | pattern | url | query | description`, each capped at 2 KB. For each `tool_result`, the text content as head 1,536 B + `…` + tail 512 B. Image blocks are dropped.
  - Doc id = `sha1(session_key + ":" + uuid)`. Several lines can share one `message.id` (streamed blocks). Each line is its own doc; `message_id` is stored so that counts can de-duplicate.
  - Session metadata:
    - `title`: last `custom-title.customTitle`, else last `ai-title.aiTitle`, else last `summary.summary`, else the first human user text, truncated to 120 characters. `title_source` records which one was used.
    - `cwd`: the first record's `cwd`. `git_branch` comes from the last record.
    - `entrypoint`: from the first record. `interactive = entrypoint ∈ {cli, claude-desktop}`.
    - `cc_version`: the last record's `version`.
    - `relocatedCwd` values are collected into `cwd_candidates`.
  - `resume_cwd` is the candidate (the first `cwd`, then each `relocatedCwd` in order) whose encoding equals the JSONL's parent directory name. Encoding: `re.sub(r'[^A-Za-z0-9-]', '-', cwd)`. If none matches, use the first `cwd` and set `resume_cwd_verified=false`.
- **Relation to existing code**: new module `memory-mcp/sessions/parse.py`, imported only by C6. It reuses nothing from the knowledge chunking code.

### 6.2 C2 `sessions.redact` — masking library (client and server, Python stdlib)

- **Responsibility**: replace secrets inside every JSON string value of every record, recursively. That includes `attachment`, `toolUseResult` and tool inputs, because the archive keeps whole records. The JSON structure is never altered.
- **Input**: a parsed record (dict), an HMAC key, and the ruleset version.
- **Output**: the masked record and per-kind counts.
- **Rules (ruleset `r1`)**:

  | Kind | Pattern (summary) |
  |---|---|
  | `aws-key` | `\b(AKIA\|ASIA)[A-Z0-9]{16}\b` |
  | `github-token` | `\bgh[pousr]_[A-Za-z0-9]{36,}\b`, `\bgithub_pat_[A-Za-z0-9_]{60,}\b` |
  | `anthropic-key` | `\bsk-ant-[A-Za-z0-9_-]{20,}` |
  | `openai-key` | `\bsk-(proj-)?[A-Za-z0-9_-]{20,}` (applied after `anthropic-key`) |
  | `slack-token` | `\bxox[abprs]-[A-Za-z0-9-]{10,}` |
  | `google-api-key` | `\bAIza[0-9A-Za-z_-]{35}\b` |
  | `gitlab-token` | `\bglpat-[A-Za-z0-9_-]{20,}` |
  | `jwt` | `\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}` |
  | `bearer` | `(?i)\bauthorization:\s*bearer\s+\S{16,}`; only the value is replaced |
  | `private-key` | `-----BEGIN [A-Z ]*PRIVATE KEY-----` … `-----END [A-Z ]*PRIVATE KEY-----`, including PGP and OpenSSH. The whole block is replaced. |
  | `config-secret` | `KEY=VALUE`, `KEY: VALUE`, `"KEY": "VALUE"` where KEY matches `(?i)(secret\|token\|passw(or)?d\|api[_-]?key\|credential\|private)`. Only VALUE is replaced, and only when it is at least 8 characters and not already a placeholder (`${…}`, `<…>`, `xxx…`, `***`, `[REDACTED`). |
  | `url-credential` | `[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@` (the password part only) |

- **Replacement**: `[REDACTED:<kind>:<hex8>]`, where `hex8` is the first 8 hex characters of `HMAC-SHA256(key, matched_value)`. The same secret produces the same tag across sessions, so a leak can be traced; the original cannot be recovered. Rotating the key changes every tag from then on, and that is acceptable.
- **Fail-closed**: with no key or an unreadable key, nothing is shipped and the cursor does not move. The error shows in `ccs status`.
- **Relation to existing code**: new. Neither repository has any redaction today. One file, `session_search/redact.py`, is vendored into the client package and the server package from the same source; the MANIFEST check (`bin/check-memory-v2-manifest`) asserts that the two copies are byte-identical.

### 6.3 C3 `ccs ingest` — client shipper (every host, Python stdlib)

- **Responsibility**: find new bytes in transcript files, mask them, and ship them. It is idempotent and resumable.
- **Input**: `--file <path>` (from the hook), `--sweep` (from the timer), or `--backfill` (first run, no budget).
- **Output**: `POST /memory/sessions/v1/ingest` and `/blob` (§7.2), plus the local state file (§7.5).
- **Diff rule**:
  - Per file, store `(dev, inode, size, offset, generation)`.
  - When the inode changes or the size shrinks below the stored offset, increment `generation` and start again from offset 0; the server replaces that generation's archive.
  - Read only up to the last `\n`; a partial trailing line waits for the next run.
  - Segments are at most 4 MB of raw input. The cursor advances only after a 2xx response.
- **Subagents**: `…/<sid>/subagents/agent-*.jsonl` is shipped with `kind=subagent` and `parent_session_id=<sid>`. These files are indexed but not archived.
- **`tool-results/`**: each file in `<sid>/tool-results/` is masked and sent once through `/blob`, keyed by name and sha256.
- **Gone files**: on `--sweep`, every state entry whose file no longer exists is reported with `jsonl_exists=false`, then dropped from state.
- **Concurrency**: a non-blocking `flock` on `~/.claude/session-search/lock` is held for each run. A run that loses the lock exits 0, and the next sweep picks up its work.
- **Budget**: a hook run handles one session and its subagents with a 20 s wall budget. A sweep has 120 s. `--backfill` has no budget. Measured: 1.2 GB parses in about 65 s on sh1-cloud, before any network time.
- **Relation to existing code**: same shape as `mirror-file-memory.rb` (state file, flock, budget, WARN log lines), but in Python so that C2 can be shared. HTTP and auth reuse the `mw_client.py` approach (stdlib, Hydra `client_credentials` on personal hosts, tailnet identity on work hosts).

### 6.4 C4 hook shim and C5 sweep timer (every host)

- **C4 responsibility**: start C3 without blocking Claude Code.
  - It reads the hook JSON from stdin and takes `transcript_path` (and `session_id` for logging).
  - It spawns `ccs ingest --file <transcript_path> --with-subagents --quiet` detached (`Process.spawn(..., pgroup: true)` + `Process.detach`) and exits 0 within 50 ms.
  - It never fails the hook. Errors go to `~/.claude/session-search.log`.
- **C4 input**: the Claude Code `Stop` and `SessionEnd` hook payloads (§7.3).
- **C4 relation to existing code**: Ruby, per the setup hook rule, at `cookbooks/claude-code/files/hooks/session-ingest.rb`, deployed by the claude-code cookbook's explicit hook list. It is registered in `files/settings.json` under `Stop` and `SessionEnd` in the same cookbook, because the `hooks` key is merged shallowly.
- **C5 responsibility**: catch everything the hook misses (kill -9, crash, headless runs with hooks disabled, hosts that were offline) and report gone files.
  - On Linux it is a systemd user timer: `OnBootSec=2min`, `OnActiveSec=2min`, `OnUnitInactiveSec=15min`.
  - On darwin it is a launchd agent with `StartInterval=900`.
- **C5 relation to existing code**: a new cookbook `cookbooks/session-search/` owns the client package, the config file and the timer, following the platform-pure convention (`darwin.rb`/`linux.rb`).

### 6.5 C6 `sessions` app — server API (ES host, inside memory-mcp)

- **Responsibility**:
  - authorize, run the C2 re-scan, run the C1 parse, and bulk-index;
  - write the archive;
  - search, preview and archive download;
  - update existence state and purge.
- **Input and output**: the routes in §7.2. They are mounted as `Mount("/memory/sessions/v1", sessions_app)` ahead of the existing `Mount("/memory", mcp)`. Both proxies already forward `/memory/*` unchanged (work `UPSTREAM_URL=…/memory`, personal nginx `location /memory/`), so neither proxy changes.
- **Ingest pipeline**:
  1. Check that the host label is on the store's allowlist (F).
  2. Decompress the gzip body.
  3. Re-scan every line with C2 in detect-only mode. Any unmasked hit rejects the segment with `422 unmasked_secret`, and the kinds are logged (never the values).
  4. Run C1.
  5. Run `_bulk` without `refresh=true`, relying on the 1 s refresh interval, which is enough for a picker.
  6. For `kind=main`, write the archive chunk.
  7. Queue the new `text` docs for embedding.
- **Archive layout**:
  - Segments: `<prefix>/<boundary>/<host>/<session_id>/<dirhash8>/g<generation>/<offset:012d>.jsonl.zst`
  - Side files: `…/tool-results/<name>.zst`
  - Writing the same offset again overwrites the same object, so retries are safe.
  - Download concatenates the chunks of the highest generation in offset order. The offsets must be contiguous; a gap marks the session `archive_complete=false`.
- **Embedding**: the existing `voyage.py` (Voyage for personal, LiteLLM `text-embedding-3-large` at 1024 dims for work). It runs in batches of 128 in a background task, so ingest latency does not depend on the provider. A failed batch is stored as `embedding_status=pending` and retried by C8. The embedding input is `text`, capped at 16 KB.
- **Relation to existing code**:
  - reuses `es_backend._bulk_index`, `ensure_indices` (403-tolerant), `_ANALYSIS` (`ja_en_hybrid`), `scoring.rrf_fuse`, `voyage.py` and `identity.py`;
  - new: `memory-mcp/sessions/{app,parse,redact,archive,search}.py`, plus MANIFEST entries;
  - new dependency: `zstandard` (server venv only);
  - new Hydra client: `session-search` (personal);
  - new identity grants for work (§7.6).

### 6.6 C7 `ccs` — picker CLI (every host, Python stdlib + fzf)

- **Responsibility**: interactive search, preview, and resume. The flags are in §7.4.
- **Mechanics**:
  - It runs `fzf --disabled --ansi --layout=reverse --delimiter='\t' --with-nth=2..`.
  - Search is wired as `--bind "start:reload(ccs _backend {q})" --bind "change:reload(ccs _backend {q})"`, with the preview as `--preview "ccs _preview {1} {q}"` in a `down,45%,wrap` window.
  - `--expect=ctrl-y` prints the command instead of running it. `ctrl-s`, `ctrl-d` and `ctrl-a` toggle semantic, deep and all; the toggle state lives in `$FZF_PROMPT`.
  - Queries shorter than 2 characters return the 50 most recent sessions.
  - `CLAUDE_CODE_SESSION_ID` (the session the picker itself runs in) is excluded.
- **Row**: `session_key \t <age> <host> <short cwd> │ <title> │ <hits>`. A hit that cannot be resumed is marked with `·` (view-only).
- **Search request**: lexical by default. With semantic on, `_backend` first returns lexical results, and a second, debounced (≥ 400 ms idle) `reload` swaps in the fused results.
- **Resume (`ccs resume <session_key>`)**:
  1. **Local file**: if the session is from this host and `jsonl_path` exists, run `chdir(resume_cwd)` then `exec claude --resume <sid> [--fork-session]`. If `resume_cwd` no longer exists, fail with a clear message instead of resuming from the wrong directory.
  2. **No local file**: if `archived` is true and `archive_complete` is true, choose a local cwd: `resume_cwd` if it exists locally, else `--to DIR`, else ask (default: current directory).
     - Download the archive into `~/.claude/projects/<encode(local_cwd)>/<sid>.jsonl.tmp`, plus `tool-results/`.
     - Verify the `X-Archive-Sha256` header, then rename the file into place.
     - If a different file with that `<sid>` already exists there, refuse unless `--force`.
     - Print `restored masked transcript (secrets appear as [REDACTED:…])`, then exec as in step 1.
     - A restored session continues on this host under a new `session_key`, and its `restored_from` field links it to the original.
  3. **Otherwise**: view-only. The preview shows why (`not archived (subagent)`, `archive incomplete`, `older than retention`).
- **Relation to existing code**: new. It shares the config, auth and HTTP layer with C3 in the same package.

### 6.7 Query design (inside C6 `search`)

- **Lexical**:
  - `bool.must = multi_match(q, ["text^2"] + (deep ? ["tool_text^0.5"] : []), operator=and)`.
  - Filters: host, cwd prefix, `interactive` (default true), `is_sidechain` (default false), `ts >= since`.
  - The query collapses on `session_key`, size 50, `_source=[session_key]`, `track_total_hits=false`. Measured p95: 20 ms.
  - Session metadata comes from one `mget` on the session index, which is about 50 small docs.
- **Hybrid**: the lexical leg as above plus `knn(embedding, k=100, num_candidates=1000, same filters)` on message docs. The two legs are fused per session with `rrf_fuse(k=60)`, using each session's best message rank. If the embedding provider is unavailable, the response carries `degraded: "bm25-only"`.
- **Ranking**: score = RRF, or BM25 alone, plus `0.05 × 2^(−age_days/30)` as a recency nudge.
- **Preview**: a separate call per session. `match` inside one `session_key`, size 6, with highlight (`fragment_size=160`). With an empty `q`, it returns the last 4 text messages.

### 6.8 C9 offline fallback (every host, inside `ccs`)

- **Trigger**:
  - the circuit breaker is open: 2 consecutive failures or timeouts at 800 ms opens it for 60 s, and the state is cached in `~/.claude/session-search/breaker.json`;
  - or `--offline` is given.
- **Mechanics**:
  1. `rg -l -F -i --glob '*.jsonl' --glob '!**/subagents/**' -- <q> ~/.claude/projects` pre-selects files (0.04 s measured).
  2. The 200 newest candidates by mtime are stream-parsed with the C1 rules, matching `q` against `text` only.
  3. Results show under a fixed `OFFLINE — local sessions only, ≤200 newest candidates` banner, so the cap is always visible.
- **Scope**: local JSONL only. There is no archive, no other hosts, and no semantic search. Resume works only for local files.
- **Relation to existing code**: it reuses the C1 parse logic, vendored as a pure-Python module.

### 6.9 C8 retention and maintenance timer (ES host)

- **Responsibility**:
  - delete each session whose `updated_at < now − 365d`: the session doc, its message docs (`delete_by_query` on `session_key`) and its archive prefix;
  - retry `embedding_status=pending` docs;
  - re-scan for masking-rule upgrades (§8, row 8).
  - It runs daily.
- **Backstop**: a lifecycle rule on the archive prefix at 395 days (GCS and S3 both have this built in), in case the job dies.
- **Relation to existing code**: work has no keeper today, so the work overlay adds a systemd timer. Personal adds a timer next to the keeper timers on CT 119.

## 7. Shared contracts (agreement required before implementation)

### 7.1 Index mappings

Index names: `memory-session` and `memory-session-message`, each with 1 shard and 1 replica on personal (single node, so 0 replicas, on work). Neither is added to `memory-all`.

- Work SLM uses the `memory-*` pattern, so both indices are covered as they are.
- Personal SLM lists indices explicitly, so both names must be added. Its drift guard only looks for `memory-fact`, so it has to be extended at the same time.
- The work `roles.json` lists index names one by one; both must be added to `memory_writer`.

#### 7.1.1 `memory-session`

```json
{
  "settings": { "number_of_shards": 1, "codec": "best_compression",
                "analysis": "<<same ja_en_hybrid as memory-knowledge>>" },
  "mappings": {
    "dynamic": "strict",
    "_meta": { "schema": "session/1" },
    "properties": {
      "session_key":       { "type": "keyword" },
      "session_id":        { "type": "keyword" },
      "host":              { "type": "keyword" },
      "project_dir":       { "type": "keyword" },
      "jsonl_path":        { "type": "keyword", "index": false },
      "cwd":               { "type": "keyword" },
      "cwd_candidates":    { "type": "keyword" },
      "resume_cwd":        { "type": "keyword" },
      "resume_cwd_verified": { "type": "boolean" },
      "title":             { "type": "text", "analyzer": "ja_en_hybrid",
                             "fields": { "raw": { "type": "keyword", "ignore_above": 256 } } },
      "title_source":      { "type": "keyword" },
      "git_branch":        { "type": "keyword" },
      "entrypoint":        { "type": "keyword" },
      "interactive":       { "type": "boolean" },
      "cc_version":        { "type": "keyword" },
      "started_at":        { "type": "date" },
      "updated_at":        { "type": "date" },
      "message_count":     { "type": "integer" },
      "text_message_count":{ "type": "integer" },
      "has_subagents":     { "type": "boolean" },
      "jsonl_exists":      { "type": "boolean" },
      "jsonl_checked_at":  { "type": "date" },
      "archived":          { "type": "boolean" },
      "archive_complete":  { "type": "boolean" },
      "archive_generation":{ "type": "integer" },
      "archive_bytes":     { "type": "long" },
      "restored_from":     { "type": "keyword" },
      "redact_version":    { "type": "keyword" },
      "parser_version":    { "type": "keyword" }
    }
  }
}
```

`session_key` = `<host>/<project_dir>/<session_id>`. A session id alone is not unique across project folders (claude-history issue #59).

#### 7.1.2 `memory-session-message`

```json
{
  "settings": { "number_of_shards": 1, "codec": "best_compression", "refresh_interval": "1s",
                "analysis": "<<same ja_en_hybrid as memory-knowledge>>" },
  "mappings": {
    "dynamic": "strict",
    "_meta": { "schema": "session-message/1" },
    "_source": { "excludes": ["embedding"] },
    "properties": {
      "session_key":   { "type": "keyword" },
      "session_id":    { "type": "keyword" },
      "host":          { "type": "keyword" },
      "cwd":           { "type": "keyword" },
      "interactive":   { "type": "boolean" },
      "uuid":          { "type": "keyword" },
      "parent_uuid":   { "type": "keyword" },
      "message_id":    { "type": "keyword" },
      "role":          { "type": "keyword" },
      "ts":            { "type": "date" },
      "is_sidechain":  { "type": "boolean" },
      "agent_id":      { "type": "keyword" },
      "text":          { "type": "text", "analyzer": "ja_en_hybrid" },
      "tool_text":     { "type": "text", "analyzer": "ja_en_hybrid" },
      "tool_names":    { "type": "keyword" },
      "embedding":     { "type": "dense_vector", "dims": 1024, "similarity": "cosine",
                         "index_options": { "type": "int8_hnsw" } },
      "embedding_status": { "type": "keyword" },
      "line_offset":   { "type": "long" },
      "redact_version":{ "type": "keyword" }
    }
  }
}
```

`host`, `cwd` and `interactive` are copied onto each message so that filters run without a join.

The §3.2 size measurement used the `standard` analyzer for `tool_text`. Switching it to `ja_en_hybrid` (so that Japanese tool output, such as fetched documents, is searchable) has to be re-measured in phase 1. If the store grows by more than 20%, the fallback is `standard`.

Embeddings are excluded from `_source`. Otherwise each doc would carry about 10 KB of float JSON, roughly 73 MB per 33 days. The estimated vector cost with int8 HNSW is about 7,300 vectors × ~1.1 KB ≈ 8 MB per 33 days. This is not measured yet.

### 7.2 HTTP API (`/memory/sessions/v1`, JSON unless stated)

| Method and path | Scope | Request | Response |
|---|---|---|---|
| `POST /ingest` | `sessions:ingest` | gzip JSON: `{client:{host, client_version, redact_version}, file:{session_id, project_dir, jsonl_path, kind:"main"\|"subagent", parent_session_id?, agent_id?}, segment:{generation, offset, end_offset, sha256, lines:[<masked JSON line>…]}}`. At most 4 MB of raw input. | `200 {session_key, indexed, next_offset, archive:"written"\|"skipped"}` · `409 {expected_offset}` · `422 {error:"unmasked_secret", kinds:[…]}` · `403 host_not_allowed` |
| `POST /blob` | `sessions:ingest` | gzip JSON: `{session_key, name, sha256, content}` (masked, tool-results only) | `200 {stored:true}` |
| `POST /state` | `sessions:ingest` | `{session_key, jsonl_exists:false}` | `200` |
| `POST /search` | `sessions:read` | `{q, mode:"lexical"\|"hybrid", deep:false, hosts?:[…], cwd_prefix?, include_headless:false, include_sidechain:false, since?, limit:50}` | `200 {sessions:[{session_key, session_id, host, title, cwd, resume_cwd, updated_at, score, hit_count, jsonl_exists, archived, archive_complete, interactive}], took_ms, degraded?}` |
| `GET /preview?session_key=&q=` | `sessions:read` | — | `200 {session:{…}, snippets:[{ts, role, fragment}]}` |
| `GET /archive?session_key=` | `sessions:read` | — | `200 application/x-ndjson` (decompressed, masked), header `X-Archive-Sha256` · `404` · `409 archive_incomplete` |
| `GET /archive/tool-results?session_key=` | `sessions:read` | — | `200 application/x-tar` |
| `DELETE /session?session_key=` | `sessions:purge` | — | `200 {deleted_docs, deleted_objects}` |
| `GET /status` | `sessions:read` | — | `200 {schema, redact_version, docs, sessions, pending_embeddings, last_retention_run}` |

### 7.3 Hook payload consumed by C4

From Claude Code on stdin, for `Stop` and `SessionEnd`:

```json
{ "session_id": "<uuid>", "transcript_path": "/abs/…/<sid>.jsonl", "cwd": "/abs/…",
  "hook_event_name": "Stop" | "SessionEnd", "stop_hook_active": false, "reason": "<SessionEnd only>" }
```

C4 reads only `transcript_path` and `session_id`, and ignores everything else. Phase 0 captures one real payload of each event on Claude Code 2.1.291 and freezes it as an adapter test fixture.

### 7.4 CLI

```
ccs [QUERY]                         open the picker
    --deep                          include tool_text (ctrl-d toggles)
    --semantic                      hybrid ranking from the first query (ctrl-s toggles)
    --all                           include headless sdk-* sessions (ctrl-a toggles)
    --sidechain                     include subagent messages
    --here                          restrict to sessions whose cwd is under $PWD
    --host H                        restrict to one host (repeatable); default: all hosts in the store
    --since DUR                     e.g. 7d, 30d; default: unlimited (retention bounds it)
    --offline                       force the local rg fallback
    --print                         print `cd <cwd> && claude --resume <id>` instead of exec (ctrl-y)
    --fork                          pass --fork-session to claude
ccs resume SESSION_KEY [--print] [--fork] [--to DIR] [--force]
ccs ingest (--file PATH [--with-subagents] | --sweep | --backfill) [--quiet]
ccs status                          endpoint, breaker, cursor lag, unknown record types, last errors
ccs purge SESSION_KEY               delete one session from ES and the archive
ccs _backend Q / ccs _preview KEY Q internal (fzf callbacks)
```

Exit codes: 0 for success or a cancelled picker, 2 for a usage error, 3 when the server is unreachable and the fallback is unusable, 4 for a resume precondition failure.

### 7.5 Client files

- `~/.config/session-search/config.json`: `{endpoint, host_label, auth:{type:"tailnet"|"client_credentials", token_url?, client_id?, secret_file?}, hmac_key_file}`. It is rendered by the boundary-owning cookbook and is mode 0600.
- `~/.config/session-search/hmac.key`: mode 0600. Work keeps it in Secret Manager (`sh1-es-memory-session-redact-key`); personal keeps it in SSM (`/memory/session-redact-hmac-key`).
- `~/.claude/session-search/state.json`: `{version:1, files:{<path>:{dev, inode, size, offset, generation, session_key, last_ok}}}`, written atomically (temp file, then rename).
- `~/.claude/session-search/{lock,breaker.json}` and `~/.claude/session-search.log`.

### 7.6 Authorization

- **Personal**: a new Hydra machine client `session-search`. `CLIENT_POLICY` is extended from `ingest,forget@dataset` to also accept `sessions:ingest`, `sessions:read` and `sessions:purge`. Hosts get ingest and read; purge is for the operator only.
- **Work**:
  - the tailnet human identity (air) gets all three scopes;
  - the box machine identity (sh1-cloud loopback) gets ingest and read;
  - the server checks host labels against `SESSION_HOSTS_ALLOWED=air,sh1-dev-instance-1`.

## 8. Failure modes and class-wide countermeasures

| # | Failure | Class-wide countermeasure |
|---|---|---|
| 1 | Server or ES unreachable during ingest | Durable per-file cursor: nothing advances without a 2xx, and the 15-minute sweep catches up from the cursor. An outage costs latency, never data, as long as the JSONL lives (30 days). |
| 2 | Server unreachable during search | The circuit breaker caches the failure for 60 s, so keystrokes never wait on dead timeouts. The C9 local fallback runs with an explicit banner. |
| 3 | Endpoint or hostname changes | Discovery from config: the endpoint lives only in the cookbook-rendered `config.json`, never in code. `ccs status` prints it and probes `/status`. |
| 4 | Claude Code changes the JSONL format (new record or block types, renamed title records, as in #51) | Lenient parser that counts unknown types and shows them in `ccs status` and `/status`; title lookup falls back through several sources. The masked raw archive means the index can be re-parsed server-side (`reindex --from-archive`) for retained sessions, with no client involved. |
| 5 | JSONL rewritten or truncated | Inode and size check bumps `generation`, and the server replaces the archive generation; ids are deterministic, so stale message docs are overwritten or purged per generation. |
| 6 | Hook does not fire (kill, crash, headless with hooks off, host asleep) | Sweep timer on every host. The hook is only an optimisation for latency. |
| 7 | Hook and sweep race on the same file | `flock`, plus deterministic doc ids and archive keys. A duplicate send is a no-op. |
| 8 | A secret slips past ruleset `r1` | Server-side re-scan rejects anything the current ruleset detects. `redact_version` is stored on every doc, and when the ruleset changes C8 re-masks the archive and ES in place. `ccs purge` is the manual path. |
| 9 | HMAC key missing on a host | Fail closed: no ingest, the cursor is held, and `ccs status` shows the reason. |
| 10 | Embedding provider down or slow | Ingest never waits on it. Docs are stored with `embedding_status=pending` and C8 backfills them; search returns `degraded:"bm25-only"`. |
| 11 | Index missing or mapping drift | `ensure_indices` at server start (403-tolerant, as today), `_meta.schema` checked on start, `dynamic: strict` so that drift fails loudly. |
| 12 | Archive chunk missing or corrupt | Contiguous-offset and sha256 checks. A failing session becomes view-only with the reason shown, and nothing half-written is restored. |
| 13 | Session id collision across project folders | `session_key` includes host and project dir. |
| 14 | Work data reaching the personal store, or the reverse | The boundary owns the config (work values only from the zp-SHIN overlay); the server-side host allowlist; no shared credentials. |
| 15 | Retention job dies | Object lifecycle at 395 days as backstop. `/status` exposes `last_retention_run`. |
| 16 | Restored session diverges from a newer copy elsewhere | A restore never overwrites an existing different file without `--force`; the restore is recorded as a new session with `restored_from`. |
| 17 | Latency regression as the index grows (≈ 11× in a year) | The keystroke path avoids highlight and `track_total_hits`. Phase 1 benchmarks at 1-year scale (synthetic 11× replication) and blocks the release if server-side p95 is 50 ms or more. |

## 9. Quantified targets

| Item | Target or estimate | Basis |
|---|---|---|
| Message docs per host | ≈ 68k per 30 days; ≈ 830k at one-year steady state | measured 75,351 per 33 days |
| Session docs per host | ≈ 1,140 per 30 days, including subagent transcripts; ≈ 190 main | measured |
| Work store total (air + sh1-cloud) | ≈ 1.7M message docs | estimate: air assumed equal to sh1-cloud, not measured |
| Search index per host-year | ≈ 0.63 GB (+ ≈ 0.09 GB vectors, estimate); ×2 on personal (replica) | measured §3.2 |
| Archive per host-year | ≈ 0.94 GB | measured §3.4 |
| Lexical search, server `took` | p95 < 50 ms at one-year scale | measured 20 ms at 33 days |
| Lexical search, end-to-end on the ES host | p95 < 100 ms | measured wall 20 ms + picker overhead |
| Lexical search from air over tailnet | p95 < RTT + 60 ms | RTT to be measured in phase 0 |
| Hybrid search, end-to-end | p95 < 600 ms | includes one embedding call; to be measured in phase 0 |
| Preview | p95 < 150 ms | single-session highlight |
| Ingest freshness | < 10 s after `Stop` (hook path); < 15 min worst case (sweep) | design |
| Backfill on a host | ≈ 65 s parse + upload of 1.2 GB raw (≈ 170 MB gzip) | measured parse time |
| Embedding cost | ≈ 5M tokens per host per 33 days (estimate), < $1 per host per month at list price | 17.7 MB of text |

## 10. Placement

| Artifact | Location now (setup) | After ADR 0013 |
|---|---|---|
| Server: `sessions/` package, MANIFEST entries | `cookbooks/lxc-es-memory/files/memory-mcp/sessions/` | `shin1ohno/ai-memory` server |
| Index JSON | `cookbooks/lxc-es-memory/files/es-indices-v2/memory-session{,-message}.json` | ai-memory |
| Shared redactor | `cookbooks/lxc-es-memory/files/session_search/redact.py` (single source, copied by MANIFEST) | ai-memory |
| Client package `ccs` + config + timer | new `cookbooks/session-search/` | package to ai-memory, cookbook stays |
| Hook shim + settings registration | `cookbooks/claude-code/files/hooks/session-ingest.rb`, `files/settings.json` | per ADR 0013 Decision 9 |
| Personal: Hydra client, SSM HMAC key, S3 bucket/prefix + IAM, SLM index list | setup (`lxc-es-memory`, `lxc-elasticsearch`) + home-monitor terraform | unchanged |
| Work: roles.json, Secret Manager key, GCS prefix + SA grant, retention timer, host config for air/sh1-cloud | zp-SHIN `projects/mercari-setup/cookbooks/gcp-es-memory` | unchanged |

Personal archive writes need a new AWS principal on CT 119, scoped to the archive prefix. That is a credential added to a host and so triggers the adversarial-review gate. It also meets ADR 0013 Decision 3 ("no new credentials on CT 119", written for GitHub access), so it must be ruled on explicitly and cannot be implied from this spec.

No new external service is introduced. GCS, S3, LiteLLM, Voyage, fzf and ripgrep are all already in use.

## 11. Delivery plan

- **Wave 0 (serial)**: freeze §7, the contracts. Then run the phase 0 probes:
  - real `Stop`/`SessionEnd` payloads;
  - whether `claude --resume` needs `tool-results/` and `subagents/` (resume after removing each);
  - the cwd encoding rule on 2.1.291;
  - tailnet RTT from air;
  - LiteLLM embedding latency;
  - kNN under the deployed licence (dense_vector kNN is Basic).
- **Parallel streams after Wave 0**, with exclusive file ownership:

  | Stream | Owns |
  |---|---|
  | S1 | Server parse + redact + ingest + archive (`memory-mcp/sessions/{parse,redact,archive,app}.py`) |
  | S2 | Server search + preview (`sessions/search.py`) |
  | S3 | Client `ccs` package (`cookbooks/session-search/files/`) |
  | S4 | Hook shim + claude-code registration |
  | S5 | Personal infrastructure (setup + home-monitor) |
  | S6 | Work overlay (zp-SHIN) |

  Concurrency is set to 3 streams at a time (S1, S3, S4 first; then S2, S5, S6) to keep review load at one PR per stream.
- **Tests**:
  - parser golden fixtures (synthetic JSONL covering every record type observed in §3.1, plus unknown types);
  - redactor test vectors (positive, negative, and placeholder cases for every kind);
  - adapter tests that feed C4 the captured real hook payload, and that feed C6 a real `ccs` request body;
  - ES integration on a scratch node (the same 9.4.2 tarball, loopback, security off);
  - the 1-year-scale latency benchmark (§8, row 17).
- **Rollout**: work first (one boundary, two hosts, loopback ES), personal second. `ccs ingest --backfill` runs once per host.

## Appendix A. Measurement method

- **Composition**: a Python pass over every `*.jsonl` under `~/.claude/projects`.
  - It counts bytes by `type`.
  - It extracts tool_result text from string or `text`-block content, and tool_use input from `command|file_path|path|pattern|url|query|description|prompt`.
  - For each N in {1, 2, 4} KB, it sums `min(len, N)` per part.
- **Index size**: a scratch ES 9.4.2 from the deployed tarball on `127.0.0.1:19200`, with security off and a 1 GB heap.
  - One doc per user/assistant record that has text or tool parts.
  - `text` uses kuromoji (baseform, cjk_width, lowercase); `tool_text` uses `standard`.
  - `best_compression`, then `_forcemerge?max_num_segments=1`, then `_cat/indices`.
- **Latency**: 20 queries ("worktree", "index.lock", "マージ", "認証", "terraform apply", "mitamae dry-run", "ブランチ", "Elasticsearch", "kuromoji", "ScheduleWakeup", "権限", "gh pr merge", "memory-work", "セッション", "timeout", "ルール", "OAuth", "スナップショット", "cookbook", "検索").
  - One warm-up pass, then 5 timed passes, measured as Python wall time over loopback.
- **Archive**: `cat` of the main JSONL piped to `gzip -6` and `zstd -3`; `tar` of every `tool-results/` directory piped to the same.
