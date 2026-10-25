# Sub-agent Design Principles — Examples & Origin Notes

## parallel-stream-file-exclusivity

Origin: 2026-05-09 two parallel streams both created the same cookbook file; one full PR cycle wasted on the merge conflict.

Zero-owner check origin: 2026-09-26 — 18 of 43 manifest modules were owned by no stream; such an entry ships as a missing module the integrator writes unplanned. A registration test taking its expected list from one stream's files instead of the manifest inherits the same blind spot. File-split example: `cookbooks/elastic-agent/files/elastic-agent.linux.yml.tmpl` vs `elastic-agent.darwin.yml.tmpl`.

## destructive-operation-scope-boundary

Origin: 2026-05-09 an agent read "consolidate dashboards" as license to delete predecessor saved objects outside its task scope.

## analysis-only-agent-scope

**Why "no immediate error" is insufficient**: an agent fixing a collection/serialization bug in a typed framework (Terraform provider, GraphQL resolver, protobuf/JSON codec) may eliminate the observable crash while introducing a subtler invariant violation — wrong list order, missing element, schema mismatch — that fails differently on a different code path. An adversarial verifier that only checks "did the panic go away?" misses it; it must check the framework's actual contract (e.g. for a Terraform list of a Required attribute, the applied value must equal the plan element-by-element in order and count).

Origin: 2026-05-31 an analysis agent stopped a panic but broke the plan-order contract; the adversarial Verify phase accepted it.

Origin: 2026-06-01 a synthesis agent restarted a production service with an unvalidated config during the analysis phase.

## auto-launched-review-agent

Origin: 2026-06/07 — 7 byte-identical double-fire pairs (10-96 s apart) plus ~10 findings-never-returned sessions; one AWS_PROFILE-global diff died 76 s in and was never re-reviewed, and one pair's only valid review was the 2nd fire after the 1st died at 96 s.

## review-agent-out-of-scope

Origin: 2026-06-15 — a security-review sub-agent prose-noted a `not_if "diff -q …"` idempotency bug in `cookbooks/mac-sudo` (0440 file unreadable without sudo → re-installs every apply) then returned `findings: []`; the bug sat unfixed for ~3 weeks.

## fleet-status-verification

| Service | Artifact check (insufficient) | Functional check (required) |
|---|---|---|
| elastic-agent | `systemctl is-active elastic-agent` | `elastic-agent status` → top-level `HEALTHY` AND metric components present, plus ES doc-count advancing |
| docker-compose stack | `docker ps` shows Up | `docker compose ps` shows `healthy` + one metric/endpoint probe |
| auto-mitamae | the drift-checker/orchestrator **cron** is present (it runs via `/etc/cron.d/`, NOT a systemd timer) | per-host `auto_mitamae_last_apply_status{...,result="success"}` in `auto-mitamae.prom`, last apply within ~2× the 5-min cycle |
| prometheus scrape | process running | `curl -s localhost:9090/-/healthy` + `targets?state=up` count |

Prompt line to include: "Report each host's FUNCTIONAL health via `<specific-command>`, NOT `systemctl is-active`. A host is HEALTHY only when the functional check confirms behavior (data flowing, components active), not just that the process runs."

Origin: 2026-06-01 a fleet agent reported 19/19 HEALTHY via `systemctl is-active` while emission had stopped.

## tool-availability-toolsearch

Origin: 2026-05-09 a stream blocked itself reporting SendMessage/EnterPlanMode unavailable — both reachable via ToolSearch.

## bulk-research-pattern

1. **Split by independence**: divide targets so each agent's work is self-contained — 1 agent = 1 brand, category, or theme
2. **Launch all agents in background in parallel**: use `run_in_background: true` for all agents in a single message
3. **Each agent's responsibility**: WebFetch reviews → fetch specs from manufacturer sites → save to the memory MCP (`remember` / `ingest`)
4. **Progress reporting**: show a progress table with agent status (researching... / **done**) and update it as each agent completes

```
Example: "Save all reviews from this page" → launch sub-agents per category in background
Example: "Look up all reviews for this brand" → 1 agent per brand in background
Example: "Find bindings for this board" → 1 agent per brand group in background
```

Cited-output verification origin: 2026-09-11 — a court-records URL returned `HTTP/2 200` with `content-type: text/html` while the body was a "page not found" title, so status-code-based verification passed it. Fabricated and misattributed citations are a standing failure mode that plausibility review never catches: one verify role corrected 24 of 43 source pages, including an attribution to an author who did not write the paper and a DOI belonging to a different article; an operator spot-check of 6 citations afterwards found zero remaining errors. Leaving rejected items in place with their reason keeps the next run from re-collecting them.

## dedup-criteria-data-model

A key that legitimately repeats (chunks of one document sharing a `doc_key`, versions sharing an id, locale rows sharing a slug) turns a plausible "same key twice = duplicate" spec into a delete order for valid data, and the downstream fixer acts on it without further review.


Origin: 2026-09-27 pro-dev — a 17-batch workflow migrated local file-memory notes into the memory v2 store, each batch followed by a verifier and a fixer allowed to `forget`. The verifier prompt said "more than one live item for a doc_key = duplicate". memory v2 splits one ingest into several items that share `doc_key` and `parent_id` and differ only in `chunk_index` (a 10 KB note became 10 items), so every multi-chunk document would have been reported as a duplicate and the fixer would have forgotten valid chunks. Caught before any verifier ran: the workflow was stopped, the prompt rewritten to "two different live parent_ids per doc_key", the fixer limited to items the batch itself created and forbidden from forgetting individual chunks, and the run resumed — the completed writers replayed from cache. The final store check (115 doc_keys, 0 duplicate parents) used the corrected invariant.

## synthesis-stage-data-by-path

Origin: 2026-08-05 — a two-phase workflow (6 discovery streams → 6 category verifiers → 1 synthesis) lost its synthesis step to `API Error: Server error mid-response`, returning `catalog: null` while all 12 upstream agents had succeeded. Two causes, both in how the synthesis call was built: the script interpolated the whole verified dataset (248KB of JSON) into the synthesis prompt, and asked one agent for a 6-section catalog in a single response. Resuming with the dataset written to a file (the prompt carried only the path plus the jq commands to read columns) and the output split across two agents by section range succeeded — the upstream agents replayed from cache, so only the synthesis re-ran. Both fixes are cheap and independent of the failure being transient: the prompt size grows with the fan-out, which is exactly the case the fan-out exists for.

## background-agent-deadline-tracking

Deadline guide — set an internal deadline at launch and, if it passes without completion, escalate in the next turn via AskUserQuestion (wait longer with a stated minute count / restart with a narrower scope / proceed without the agent's output):

- Research / codebase audit: **15 min**
- Plan-level analysis (Ultraplan, multi-repo design): **30 min**
- Large multi-repo audit or domain research: **60 min**

Polling cadence: every 5-10 min against observable state (`journal.jsonl`, `TaskList`, the output file), emitting a 1-line progress note each time. Do not go silent between polls.

Stall detection — observe BEFORE kill. Judge "progress" by the observation source that actually updates during the run. For an in-session Task-tool agent that is `journal.jsonl` / `TaskList`; for an external headless `claude -p` process it is that process's transcript JSONL (`~/.claude/projects/<proj-dir>/<uuid>.jsonl` — stdout arrives only at exit, but the transcript is written incrementally). Absence of an EXTERNAL artifact (no commit / PR for N minutes) is NOT evidence of a stall — the agent may be recovering from a working-tree collision, and killing it there strands nearly-finished work. `TaskStop` / kill only when tool activity on the observation source is zero across 2 consecutive probes, and read the transcript tail to classify stuck vs recovering before killing.

Do not re-launch the same agent with the same prompt expecting a different result. If it silently fails once, the second attempt usually fails the same way — narrow the scope or switch tools.

Origin: 2026-07 aa4b0e75 (status? asked 3× + 2 stall reports in one session) / 29d690f1 (30 min silent, user prompted "止まってませんか") / 2ec1c07b.

Origin: 2026-04-23 two consecutive Ultraplan agents failed silently; the user had to notice and restart.

Origin: 2026-06-27 bca7dadc — a resolve session that looked "13-min stuck" was in fact recovering from a shared-tree collision; the kill was the direct cause of the issue going unresolved. This is why the kill gate is "2 consecutive zero-activity probes + transcript tail", not elapsed silence.

Why "emit before asked": the reactive wording recurred in four sessions after the hook landed (2026-08-17 / 09-07 / 09-08 / 09-11, e.g. 「結局 setup の改善計画はどうなってますか？」), so a "status?" question is treated as evidence the discipline already failed, not as a question to answer. An observation loop that dies takes the progress obligation with it silently — a Monitor timeout notice or a watcher's failed notification is a signal that observation broke, not "nothing to report".

Origin (the mechanical backstop): 2026-07-28〜08-05, five sessions where the USER had to ask whether the agent was alive — 「SubAgent動いてなくないですか？」(cd0e58ba) /「続けて、SubAgentの様子も確認」(6dce40db) /「続けて。workflowが止まってるように見える」(95c93439) /「終わってませんか？」(18721f4c) /「左のpaneのAgentの状況わかる？」(a15e3419). All five post-date the rule's own codification, which is the evidence that moved this from prose-only to a Stop hook (`hooks/warn-background-launch-no-progress.rb`). The hook is non-blocking by the same reasoning as `detect-prose-menu.rb`: a legitimately-parked background job must still be able to end its turn, so the hook reminds rather than traps.

## 60-second-rule

Pattern: launch with `run_in_background: true`, emit one short user-facing line ("Deploy in background, waiting for completion notification"), keep interacting, and feed results back when the completion notification arrives.

Origin: 2026-04-23 attempted `docker compose up -d --build` inline as a foreground Bash call; user corrected "時間がかかるタスクは SubAgent で".

## agent-team-messaging-contract

Origin: 2026-06-18 zp-SHIN ×3 sessions — the lead sent with `to:"main"` and was rejected (「You are the main conversation — "main" addresses you. Send to a named agent instead.」); 4/4 teammates finished and emitted findings as plain text that never reached the lead, and the team-lead ran a SendMessage re-request round-trip (0bc32f7d). 2026-07-06 ×2 sessions — the lead re-sent the full task prompt and the worker defended with 「再送要求と判断し、検証済みの同じ完全レポートを再送します」 (45450f91); a teammate whose deliverable was already collected was not shut down until the user prompted 「動作が終わったSubAgentは閉じれますか？」 (da4dcecc).

No hook: `to:"main"` is already rejected by the harness itself (the mechanical enforcement exists; the rule's value is avoiding the wasted turns up front). The remaining items are prompt-composition / agent-judgment problems a PreToolUse hook cannot inspect.

Lead-side rules origin: 2026-09-16 — two of four streams went idle without output and were diagnosed as plan-mode blocking, while another stream wrote its file during that same plan mode. The Stop hook `hooks/warn-background-launch-no-progress.rb` also fires when a teammate's idle notification arrived with no delivered findings and no resend request by turn end — added 2026-08-23 after two teammates in one session idled silently, two months after the prose rule landed.

## scratch-file-discipline

Origin: 2026-07-08 — a ruby agent's fake-remind stub landed in `cookbooks/.../todo-collect/` and blocked the post-merge pull with "untracked working tree files would be overwritten by merge". The `warn-untracked-before-pull.rb` hook is the warn-only backstop; the prompt-side pin to `$TMPDIR` is the prevention.

## mandatory-delegation-blocks

The five blocks are text to paste, which is why they live in the always-loaded rule and not here; this section holds only their origins.

1. Chunked reading — 2026-09-03: made mandatory after a predecessor died of context overflow twice on the same job (「読み方の規律が最重要です」); one template repeated the same text 23 times in a single batch.
2. Safety boundary — 2026-08-23: copied into six or more agents in one batch.
3. Untrusted data — 2026-08-23: copied into five or more agents in one batch. It is the general-data extension of the `source_class` judgement in `knowledge-persistence.md`.
4. Output shape — 2026-09-03.
5. Self-check — 2026-09-11: an investigation node's artifact mentioned the target's actual title zero times. Receiving-side count — 2026-09-16: a mechanical gate cleared 6 files and 27 sources while the domain's proper nouns appeared zero times in the body; both the delegate's own self-check and the gate had passed a topic mismatch.
