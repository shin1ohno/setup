# Refactoring result (2026-06, vs baseline.md)

FINAL (2026-06-13). #480 weave / #481 pro-router / #482 consent merged +
canary-validated on their real CTs (apply exit 0, services healthy, no restart;
fleet auto_mitamae 19/19 success). case-B PR 4-3b (lxc-consent) merged + verified
(home-monitor PR #95 granted pve-bootstrap-ssm /hydra/* + aws/ssm decrypt;
DECRYPT_OK on CT 110; the 3 /hydra/* reads succeed via the profile). Only #479
local-mcp (Air offline) + lxc-hydra case-B (needs /memory/* grant) are open.
Baseline measured on `main` @ `2ee9f1b` (see baseline.md).

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

## Done since the preliminary draft

- #480/#481/#482 merged + canary-validated on weave/pro-router/consent CTs
  (apply exit 0; weave 4 containers + "Up 11 days", pro-router table-52 clean +
  LAN OK, consent "Up 10 days"); fleet converged to 19/19 success.
- home-monitor PR #95 (pve-bootstrap-ssm /hydra/* + aws/ssm kms:Decrypt) merged +
  applied; live decrypt probe on CT 110 = DECRYPT_OK.
- case-B PR 4-3b: lxc-consent migrated to --profile pve-bootstrap-ssm; the 3
  /hydra/* reads verified working via the profile.

## Remaining (genuinely external)

- **#479 local-mcp**: Air (Mac) offline ≥2 days (tailscale "last seen 2d ago").
  CI-green, behavior-preserving deploy_with_ssm_env adoption; apply on Air when
  it is next online (`COOKBOOK=local-mcp ./bin/mitamae local test-cookbook.rb`).
- **lxc-hydra case-B**: also reads /memory/aurora-endpoint, which pve-bootstrap-ssm
  cannot read (probe MEMORY_FAIL). Needs a separate /memory/* grant before
  migrating off bare; left bare (operator-seeded .env, working).
- Optional/low-value: starship mise migration; compose_service `--remove-orphans`
  extension for monitoring/praeco; systemd_unit install-only mode for unbound-watchdog.
