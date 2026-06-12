# Refactoring baseline (Phase 0, measured 2026-06-13)

Snapshot of the repository at the start of the full refactoring (plan.md). All
numbers are `git ls-files`-based (tracked content only), measured on the
`refactor/phase0-guardrails` branch off `main` @ `2ee9f1b`.

## Size

| Metric | Value |
|---|---|
| Cookbooks (`cookbooks/*/default.rb`, tracked) | 145 |
| Recipe Ruby lines (`cookbooks` + `roles` + `pve` + root `*.rb`, `files/` excluded) | 16,679 |
| Recipe-tree `*.rb` lines (incl. `cookbooks/*/files/*.rb`: 16,679 + 175) | 16,854 |
| Entry recipes | `darwin.rb`, `linux.rb`, `test-cookbook.rb`, `pve/*.rb` (20 pve recipes incl. `pve-host.rb`) |

Note: `ls -d cookbooks/*/` reports 146 dirs, but `cookbooks/self-heal/` is an
**untracked empty directory** (0 git-tracked files) — local cruft, not a
cookbook. Tracked cookbook count is 145. See plan.md 発見事項.

## Guardrail state (Phase 0 scripts, current main)

| Script | Result on main |
|---|---|
| `bin/audit-cookbook-reachability` | 137 reachable + 8 allowlisted (dead) = 145 → **exit 0** |
| `bin/lint-cookbooks` (179 recipes) | 0 violations → **exit 0** |

Allowlisted-unreachable (dead) cookbooks, 8: `ruby`, `openssl`, `autoconf`,
`disable-ipv6`, `im-select`, `memory-server`, `oh-my-zsh`, `typewritten`.
`consent-app` is reachable via a file-store edge (read by path from
`pve/lxc-consent.rb`), not `include_cookbook` — see the audit script header.

## Phase 1 deletion impact (dead 8)

| cookbook | tracked files | recipe lines |
|---|---|---|
| `ruby` | 3 | 0 (empty default.rb) |
| `openssl` | 3 | 87 |
| `autoconf` | 3 | 5 |
| `disable-ipv6` | 2 | 41 |
| `im-select` | 3 | 6 |
| `memory-server` | 1 | 169 |
| `oh-my-zsh` | 3 | 42 |
| `typewritten` | 3 | 25 |
| **total** | **21** | **375** |

## Duplication clusters (measured vs plan estimate)

The plan's cluster sizes were rough pre-survey estimates. Measured on main:

| Cluster | Plan estimate | Measured | Detail |
|---|---|---|---|
| systemd 4-step hand-written (`daemon-reload` proxy) | 24 cookbook | **17** cookbook | `rg -l daemon-reload cookbooks --glob '!**/files/**'` |
| docker compose deploy hand-written (`docker compose up -d`, not `compose_service`) | 10 cookbook | **2** cookbook | `lxc-monitoring`, `lxc-praeco` only — the rest of the plan's G2 list either already use `compose_service` or deploy compose differently |
| `compose_service` DSL already adopted | (ref: 3) | **6** recipe | `lxc-cognee`, `lxc-memory`, `lxc-roon-mcp`, `local-mcp`, `pve/lxc-weave`, `pve/lxc-consent` |
| `require_external_auth` SSM-env gates | 9 cookbook | **21** call sites / 20 files | see check_command classification below |

The compose-cluster divergence (10 → 2) materially narrows Phase 2 G2 scope:
the hand-written `docker compose up -d` work is `lxc-monitoring` + `lxc-praeco`.
Other G2 members are touched for `deploy_with_ssm_env` / systemd, not compose.

## check_command profile classification (case B / D5, 26 call sites)

Precisely extracted (continuation + variable resolution + `instructions`
excluded). On main, `bin/lint-cookbooks` finds **0** profile MISMATCHes — every
gate is internally consistent.

| Class | Count | Sites |
|---|---|---|
| BARE | 4 | `cookbooks/lxc-hydra:127`, `cookbooks/mcp:55`, `cookbooks/memory-server:77`, `pve/lxc-consent:131` |
| EXPLICIT (`--profile`/`AWS_PROFILE`) | 21 | elastic-agent×3, lxc-cognee, lxc-memory, lxc-monitoring×2, lxc-praeco, lxc-kibana×2, lxc-elasticsearch×2, lxc-apm-server, lxc-roon-mcp, mcp-probe, local-mcp, edge-agent, auto-mitamae-{target,orchestrator}, ssh-keys, pve/lxc-weave |
| STS | 1 | `cookbooks/codex-cli:53` |

Case-B migration targets (BARE → EXPLICIT, LXC-only): `lxc-hydra`, `lxc-consent`.
`mcp`/`codex-cli` stay bare/STS (darwin default-profile, allowlisted in lint).
`memory-server` is deleted in Phase 1.

## Goal

Cookbooks 145 → ~135 (delete 8 dead + fold file-store/dormant), recipe lines
-10% (~16,680 → ~15,000) via DSL consolidation (`systemd_unit`,
`deploy_with_ssm_env`, `compose_service` adoption). Tracked in plan.md;
final comparison in `docs/refactoring/result.md` (Phase 5).
