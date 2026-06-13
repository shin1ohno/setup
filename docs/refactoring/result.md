# Refactoring result (2026-06, vs baseline.md)

PRELIMINARY — finalize when the canary-gated PRs (#479 local-mcp, #480 weave,
#481 pro-router, #482 consent) and the case-B PR 4-3b merge. Baseline measured
on `main` @ `2ee9f1b` (see baseline.md).

## Outcome by phase

| Phase | Result | PRs |
|---|---|---|
| 0 guardrails | done — `bin/audit-cookbook-reachability` + `bin/lint-cookbooks` in CI; 4-agent adversarial audit fixed 5 issues | #470 |
| 1 dead/residue | done — 8 dead/dormant cookbooks + ruby32 + docs residue deleted; allowlist emptied | #471 #472 #473 #475 |
| 2-0 DSL defs | done — `systemd_unit` + `deploy_with_ssm_env` added (not applied) | #474 |
| 2-1 systemd_unit | done — node-exporter adopted (no-op on converged) | #477 |
| 2 G1 sweep | CLOSED (empty) — only node-exporter fit; rest are doc-heredocs / --user / mask | — |
| 2 G2 | local-mcp adopted deploy_with_ssm_env (canary/Mac-apply pending); other G2 cookbooks have per-cookbook flows (keystore/cert/multi-gate) that don't fit the helper | #479 |
| 3 install | ruby 3.3 unified; mise survey → opportunity exhausted (defer); python/rust → keep pyenv/rustup | #475 #476 |
| 4 structure | lxc-weave / lxc-pro-router / lxc-consent inline logic extracted to cookbooks (canary pending); node[:setup] + roles boundary audited clean | #480 #481 #482 |
| 5 close | CLAUDE.md conventions + DSL docs (this PR); Cognee save + retro pending |  |

## Metrics

| Metric | baseline | merged-so-far | after canary PRs merge |
|---|---|---|---|
| Cookbooks (tracked default.rb) | 145 | 136 | 139 (Phase 4 extraction ADDS lxc-weave/pro-router/consent cookbooks; logic moves out of pve entries) |
| Reachability ALLOWLIST | 8 (dead) | 0 (empty) | 0 |
| Dead/unreachable cookbooks | 8 | 0 | 0 |

Note: the original "~135 cookbooks" goal assumed deletion would dominate. Net
count is ~flat because Phase 4 extraction trades 3 fat pve entries for 3 thin
entries + 3 cookbooks. The real wins are: zero dead code (allowlist empty), CI
guardrails, and the consolidated entry-recipe shape — not raw count.

## Key corrections to the plan's estimates (measured, not assumed)

- "systemd 24-cookbook sweep" → effectively 1 (node-exporter). The rest were
  README heredocs, `--user` timers, or unit mask/patch — not systemd_unit-shaped.
- "compose 10-cookbook" → 2 hand-written (monitoring/praeco), and both need a
  `compose_service` `--remove-orphans`/3-file-gate extension; ES/kibana/apm are
  native systemd, not compose.
- `deploy_with_ssm_env` cleanly fit only local-mcp (cognee-shape); the other
  ssm-env cookbooks have cert-fetch / keystore / multi-gate flows.
- Lesson (codified in retro): classify real-resource vs doc-heredoc vs
  `--user` vs guard BEFORE scoping a "mechanical sweep".

## Remaining (needs real-machine `!`)

- Canary-validate + merge #479 (Air apply) / #480 / #481 (table-52) / #482 (OAuth).
- case-B `/hydra/*` profile probe → PR 4-3b (lxc-consent + lxc-hydra bare→--profile).
- Optional: starship mise migration (low value); compose_service helper extension
  for monitoring/praeco; systemd_unit install-only mode for unbound-watchdog.
