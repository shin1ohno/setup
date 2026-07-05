---
name: web-crawl
description: Config-driven web crawler — monitor known sites, run topic-radar searches, or recursively crawl a seed URL; dedups and persists findings to memory (pluggable sink). Run manually as /web-crawl or as a scheduled cloud task via /schedule.
user-invocable: true
argument-hint: "[target-name | url | 'topic:<query>'] [--mode monitor|radar|crawl] [--depth N] [--sink memory|es]"
---

# Web Crawl Skill

## Purpose

A single, config-driven web crawler with three acquisition modes (monitor / radar / crawl) and a pluggable persistence sink. Findings are deduplicated and persisted to memory by default. Run it manually with `/web-crawl`, or register the same procedure as a scheduled cloud task via `/schedule`.

Two orthogonal axes:

| Axis | Role | Values |
|---|---|---|
| **mode** (acquisition) | how pages are found / fetched | `monitor` / `radar` / `crawl` |
| **sink** (transform + persist) | page → what, to where | `memory` (summary → knowledge, **default, implemented**) / `es` (structured record → dedicated index, **future — stub**) |

Increasing acquisition modes never changes a sink; adding a sink never changes acquisition. That orthogonality is the extension point (e.g. price tracking = any mode + `sink: es`).

## Argument Parsing

`$ARGUMENTS` selects the target(s):

- **empty** → run every target in the config.
- **`<target-name>`** (matches a config `name`) → run just that target with its config values.
- **a bare URL** → ad-hoc `monitor` on that URL (no config entry needed).
- **`topic:<query>`** → ad-hoc `radar` with that search query.

Flags override the resolved target's config: `--mode monitor|radar|crawl`, `--depth N` (crawl only), `--sink memory|es`.

## Step 1: Load Config

Load and merge target definitions in this precedence order (later wins on same `name`):

1. **Canonical (shared, public)** — fetch the repo config over plain HTTP (no MCP / auth / checkout needed; works identically locally and in the cloud):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/shin1ohno/setup/main/config/web-crawl-targets.yaml
   ```
   In a cloud `/schedule` run, use WebFetch on the same URL instead of `curl`.
   > Until this skill's PR merges to `main`, that URL 404s. Pre-merge, read the working-tree `config/web-crawl-targets.yaml` (local) or the branch raw URL.
2. **Local override (optional, private)** — `~/.claude/web-crawl/targets.local.yaml` if it exists. Merge on top of the canonical set, matching by `name`. This is where **private or sensitive** targets go — they never get committed. (Same convention as `~/.claude/settings.local.json` / `.env`.)

If neither source yields any target and `$ARGUMENTS` gave no ad-hoc URL/topic, report "no targets configured" and stop (graceful empty-state).

A target entry:
```yaml
- name: <unique>
  mode: monitor | radar | crawl
  urls: [<url>, ...]        # monitor
  query: "<search query>"  # radar
  seed: <url>              # crawl
  depth: <N>               # crawl (default 1, cap 3)
  sink: memory             # or: { type: es, index: <name> }
  extract: {...}           # es only: fields to pull from each page
  tags: [<tag>, ...]
```

## Step 2: Acquire (by mode)

**Bounds (all modes):** max 50 pages fetched per target per run; per-fetch timeout; on `crawl`, stay on the **seed's domain** only and honor `depth`. If you hit a cap, say so explicitly in the report ("stopped at 50/… pages") — never silently truncate. **Public content only** — do not crawl authenticated or internal URLs; route anything sensitive to the local override and a non-memory sink.

- **monitor** — WebFetch each `urls` entry. Extract the discrete items on the page (release entries, changelog headings, list items, article links). These candidates go to Step 3.
- **radar** — WebSearch `query`. Collect result URLs + titles as candidates. Optionally WebFetch the top results for a fuller summary.
- **crawl** — WebFetch `seed`; extract same-domain links; BFS to `depth` (respecting the page cap); extract the main textual content of each fetched page as a candidate.

## Step 3: Persist (by sink) — with dedup

Compute a stable key per candidate: the **normalized URL** (strip fragments/tracking params; lowercase host). Maintain an **in-session seen-set** of keys handled this run — do not rely on a just-written memory becoming immediately recallable (memory reconciles asynchronously).

### sink: `memory` (default — implemented)

For each candidate not already known:

1. **Dedup check** — `recall(query=<url or title>, filters={tags:[<target-name>]}, top_k=5)`. If a prior memory clearly covers this URL/item, skip it (count as skipped). Also skip if its key is in the in-session seen-set.
2. **Persist** — `remember(content=<concise summary: title, 1–2 line gist, url>, type='knowledge', tags=[<target-name>, 'web-crawl', <YYYY-MM-DD>])`.
3. Add the key to the seen-set.

### sink: `es` (future — stub)

If a resolved target has `sink.type: es` (or `--sink es`), **do not attempt a write**. Stop that target with an explicit message:

> `es` sink is not implemented in v1. Structured/time-series persistence (e.g. price tracking) is a separate PR. Reference schema `web-crawl-prices` and the cloud→ES reachability note are in issue #650 (追記2). Use `sink: memory` for now, or implement the ES adapter.

(The future adapter will append one doc per observation to a dedicated ES index — `@timestamp`/`item`/`price:scaled_float`/`currency`/… — reachable from local via the ES endpoint and, for cloud runs, via a tailnet/public ingest path that must be built then.)

## Step 4: Report (BLUF)

```
## web-crawl — <target(s)>
persisted: <N>   skipped(dedup): <M>   [truncated: <if any>]

### New this run
1. <title> — <one-line gist> — <url>
...
```

If nothing new: report "no new items" and stop cleanly.

## Scheduling as a cloud task (`/schedule`)

Register a cloud routine whose prompt is **self-contained**: the cloud environment does not run mitamae, so this skill is not auto-loaded there. Inline this skill's procedure into the prompt; the targets are NOT inlined — the prompt fetches them from the canonical raw URL (Step 1), so adding a target later needs only a `git push`, not a routine edit.

Checklist when registering:

- **cron in UTC** (convert from Asia/Tokyo = UTC+9). One routine = one job.
- Attach the **memory MCP** in the routine's `mcp_connections` so `recall`/`remember` work in the cloud environment.
- **Graceful empty-state**: no new items → finish successfully, do not error.
- **Verify after registering**: run the routine once immediately (`/schedule … run`), then `recall(filters={tags:['web-crawl', <today>]})` to confirm the cloud write landed before trusting the schedule.
