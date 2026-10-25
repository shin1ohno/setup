---
paths:
  - "cookbooks/**"
  - "roles/**"
  - "pve/**"
  - "bin/**"
  - "config/**"
  - "*.rb"
  - "test-cookbook.rb"
  - ".github/workflows/**"
---

# Cookbook Conventions (setup)

Path-scoped part of the project CLAUDE.md.

## Development Patterns

**Adding New Tools:**

1. Create cookbook in `cookbooks/[tool-name]/default.rb`
2. Add to appropriate role in `roles/[role-name]/default.rb`
3. Use conditional checks (`not_if`, `only_if`) to prevent redundant execution

**Cookbook Best Practices:**

- Use `not_if "which [command]"` or `test -f [file]` for installation checks
- Use `add_profile` helper for shell environment setup
- Platform-specific logic: never `node[:platform]` control flow inside a cookbook — see the platform-pure convention below
- Always include user/group/mode for file operations
- **External URLs**: Verify external resources (GitHub releases, Homebrew packages, URLs) with `curl -sI` before commit. Dry-run does not fetch external resources — it is not evidence that a URL exists

**Custom Helpers Available** (defined in `cookbooks/functions/default.rb`):

- `include_role(name)` / `include_cookbook(name)` - Include from `roles/` or `cookbooks/`
- `require_external_auth(tool_name:, check_command:, instructions:, skip_if:)` - Gate cookbook on external auth (SSM, gh, etc.); skips in non-TTY contexts
- `prepend_path(*dirs)` - Prepend dirs to PATH for the current recipe run
- `brew_formula?(name)` / `brew_cask?(name)` / `brew_tap?(name)` - Cached lookup against `brew list/tap` (cache populated by `cookbooks/homebrew`)
- `lxc_entry(tags:, elastic_agent_extra:)` - LXC entry-recipe tail: `include_role "lxc-core"` (node-exporter + auto-mitamae-target) + `include_cookbook "elastic-agent::linux"` tagged with `tags` + `include_cookbook "gate-report"` (end-of-apply gate visibility)
- `compose_service "<name>" do … end` - docker-compose deploy pair: `ensure <name> running` (idempotency-probed `up -d`) + notify-driven `restart <name>` (`up -d --force-recreate`). Params: `compose_path`, `deploy_dir`, `env_path`, `buildkit`, `build_flag`, `wait`. Reference adopters: lxc-consent / lxc-roon-mcp / lxc-weave
- `systemd_unit "<name>.service|.timer" do staging_path … end` - install an already-staged unit + activate correctly (.service: enable+restart; .timer: enable+restart timer+start companion). The CALLER stages via its own `remote_file source "files/<unit>"` (a `remote_file` inside a `define` resolves relative to `cookbooks/functions/`, not the call site). Adopter: node-exporter
- `deploy_with_ssm_env "<name>" do … end` - SSM-gated `.env`: `require_external_auth` + generate + `remote_file` + temp-delete, with content-aware `skip_if` (`expected_keys`). Fits the single-generate→copy→delete shape (local-mcp); cookbooks with cert-fetch / keystore / multi-gate flows keep their explicit form

**Node Configuration Access:**

- `node[:setup][:root]` - Setup directory path (~/.setup_shin1ohno)
- `node[:setup][:user]` - Current user
- `node[:platform]` - Platform (darwin/ubuntu/arch)
- `node[:homebrew][:prefix]` - Homebrew installation path

**Conventions (audited/established by the 2026-06 refactor + the 2026-08 hurdle-removal campaign — see `docs/refactoring/`):**

- **node[:setup]/[:homebrew]/[:profile] are resolved ONCE** in `cookbooks/host-profile` (included first by `cookbooks/functions/default.rb`). Cookbooks READ these; never re-derive them with a local `node.reverse_merge!(setup: {...})` (that pattern was de-duplicated from 22 sites). Per-host identity comes from `node[:profile][:label]` (e.g. `air`), also host-profile-resolved. Cross-platform hardware facts (`node[:hw][:machine]`, `node[:hw][:ncpu]`) are host-profile-resolved too — never re-run `uname -m` / `nproc` in a cookbook.
- **Cookbooks are platform-pure — no `node[:platform]` control flow inside cookbooks/** (2026-08 stream-B migration, PRs #807-#825; `bin/lint-cookbooks` check 12 enforces; allowlist = functions + host-profile, the platform abstraction owners). OS selection happens at the CALLER: a single-OS caller includes the per-OS recipe statically (`include_cookbook "elastic-agent::linux"`), a dual-OS role uses `include_platform_cookbook`, and a single-OS cookbook carries a `cookbooks/<name>/platform` marker ("darwin"|"linux") that makes a cross-OS include raise instead of silently no-opping. Value-only differences use `install_package` (package names), `platform_value(darwin:, linux:)` (paths/tokens/flags), or `node[:hw]` facts. Split shape: `darwin.rb` + `linux.rb` (no default.rb), shared fragments ≥2 resources or ≥5 lines go to a sub-recipe (`common.rb`) included via bare `include_recipe`.
- **Roles partition cookbooks — no cookbook is included by two roles.** Each cookbook is owned by exactly one of core/foundation/extras/llm/lxc-core/manage/network/programming/server. Keep it that way (verified: zero cross-role duplicate includes).
- **LXC entry recipes stay thin**: `include functions` → `include_cookbook "lxc-<name>"` → `lxc_entry(...)`. Service logic lives in `cookbooks/lxc-<name>/`, not inline in `pve/lxc-<name>.rb` (reference: lxc-roon-mcp, lxc-weave, lxc-pro-router, lxc-consent).
- **Guardrails run in CI** (`syntax-check` job): `bin/audit-cookbook-reachability` (no dead/unreachable cookbook; ALLOWLIST is empty; per-OS split cookbooks need BOTH darwin.rb+linux.rb with no orphans; no stale include — an include whose target recipe file does not exist, the shape a per-OS split leaves behind) + `bin/lint-cookbooks` (FAIL + WARN tiers covering the mitamae footguns — compile-time `File.exist?`, Integer owner/group, auth-gate profile mismatch, deploy-list drift, cross-file registry consistency, the `node[:platform]`-in-cookbooks ratchet, and more). The linter's own header comment is the canonical check list — read it there rather than trusting this summary. Run both before committing a cookbook change.
- **AWS profile resolution — two tiers, never the ambient `default`**: fleet/LXC cookbooks pin an EXPLICIT `--profile` (the scoped `pve-bootstrap-ssm`, read from `cookbooks/ssh-keys/files/aws-config.json`) so the gate is deterministic on the **non-TTY** fleet (auto-discovery is TTY-only and never runs there). darwin/admin cookbooks either use a BARE gate + `require_external_auth` profile auto-discovery (`mcp`, `local-mcp` — operator needs no profile name) or an explicitly-named admin profile (`sh1admn`, for `ce:*`/admin-scope work like `aws-cost-monitor`; `elastic-agent` darwin branch). Nothing relies on the per-machine ambient `default`. `pve-bootstrap-ssm` is least-privilege (scoped SSM read on `/ssh-keys/* /monitoring/* /hydra/* /memory/*` + per-path KMS `EncryptionContext`) — **NEVER give an unattended fleet LXC admin (`sh1admn`) keys** (blast-radius containment; a compromised network-exposed LXC must not reach admin/billing). `lint-cookbooks` check #3 enforces gate==invocation profile per cookbook. Origin: 2026-06 AWS-profile design review (multi-lens; chose two-tier "Option E") + the cognee/memory/hydra fleet pin-vs-grant fix.

## Cross-repo Host Registry (Phase A round-table 2026-05-07)

Host registry の canonical source は **AWS SSM Parameter `/host-registry/devices`**。実体は `~/ManagedProjects/home-monitor/contracts/devices.json` (git-managed、19 エントリ: 5 hosts + 12 LXCs + 2 iOS clients)、Terraform で SSM に push。setup cookbook と CI は SSM から fetch:

| Component | Role |
|---|---|
| `cookbooks/ssh-keys/files/aws-config.json` | Bootstrap minimal config (`aws_profile` + `aws_region` のみ、SSM 接続用) |
| `cookbooks/ssh-keys/default.rb` | `aws ssm get-parameter --name /host-registry/devices` で fetch、新ネスト型スキーマ (`d["ssh"]["ssm_prefix"]` 等) で参照 |
| `.github/workflows/test-setup.yml` `ssm-validation` job | GitHub OIDC role (`AWS_OIDC_ROLE_ARN` secret) で SSM fetch + jq sanity check |

3 cookbook (`auto-mitamae-orchestrator` / `auto-mitamae-target` / `lxc-monitoring`) は `aws-config.json` から `aws_profile` / `aws_region` のみ参照 (devices map に touch せず)。

新ホストの追加: `home-monitor/contracts/devices.json` に entry を追加 + `terraform apply` (`kind: lxc` なら `pve/lxc-<name>.rb` も追加)。setup repo の cookbook 修正は不要。

廃案 (Phase A round-table で却下): submodule 経由配送 (cross-VCS auth + protocol.codecommit.allow=always 運用負担)、第 3 リポ抽出 (privilege aggregation anti-pattern)、モノレポ化 (IAM 信頼境界破壊)。詳細: `docs/adr/0001-0004-*.md`。アプリケーションだけのリポ (ai-memory、IAM・KMS・SSM 書き込みを持たない) はこの却下の対象外 (`docs/adr/0013-ai-memory-own-repo.md`)。
