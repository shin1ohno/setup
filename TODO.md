# TODO

## Roon process-name toggles re-fire 4 false "Process down" alerts per update (Medium)

`setup-process-alerts.sh` builds one `.es-query` rule per (host, process) pair and
matches `process.name` with an exact `term` query. Roon Server's launcher
alternates between exec'ing `./RoonServer.exe` and
`/opt/RoonServer/Server/RoonServer` across auto-updates, so the comm-derived
`process.name` toggles between the `.exe` and extension-less spellings while the
on-disk file and `process.executable` stay put. Every toggle makes all four Roon
rules (`roon` ×3 + `pro` ×1) match zero docs and fire a false "Process down" that
can never auto-resolve, because the name they query no longer exists.

- **Observed twice in 3 days**: 2026-08-04T17:01Z (extension-less -> `.exe`,
  issues #829-#832, fixed by PR #833) and 2026-08-06T19:04Z (`.exe` ->
  extension-less, issues #848-#850, fixed by the PR that adds this entry). Both
  handovers were gapless in `metrics-system.process-default` — Roon never went
  down. Each occurrence costs 4 false issues plus a name-flip PR.
- **Why the current fix does not close it**: flipping the four values in
  `expected-processes.json` tracks the name Roon happens to use today. It is
  correct until the next toggle and then wrong in exactly the same way. Listing
  both spellings does NOT work either — each list element becomes its own rule,
  so the currently-absent spelling would fire permanently.
- **First step**: teach `setup-process-alerts.sh` to accept a list of
  alternative spellings for ONE rule — let an entry be a nested array
  (`["RoonServer", "RoonServer.exe"]`) built into a `terms` query (OR) instead of
  a `term` query, with a flat string keeping today's exact-match behaviour. Keep
  the rule name keyed on the first spelling so the prune phase stays stable, and
  verify against live ES that the rebuilt rules still match for every existing
  host before rollout (a wrong `terms` shape would silently blind every
  process-liveness rule in the fleet). Delete this entry in the resolving commit.

## Elastic CA rotation is not detected by the cert skip_if guards (Medium)

The content-aware `skip_if` migration (PR "content-aware skip_if") changed the
two Elastic CA fetch gates from `File.exist?` to
`file_has_all?(path, ["BEGIN CERTIFICATE"])` —
`cookbooks/lxc-monitoring/default.rb` (`/data/monitoring/vector/elastic-ca.crt`)
and `cookbooks/elastic-agent/linux.rb` (`/etc/elastic-agent/certs/ca.crt` —
the cookbook was split per-OS in #816; the gate lives on the linux side).
That upgrade catches a truncated or error-text file, but **CA rotation is an
explicit non-goal of it**: an OLD but well-formed PEM still satisfies the
needle, so the gate keeps skipping.

- **Trigger**: Terraform rotates the CA in SSM `/monitoring/elastic/ca/cert`
  (ADR 0005 §認証 puts CA validity at 2 years) and every already-converged host
  keeps serving the old PEM. Vector's `[sinks.elasticsearch].tls.ca_file` and
  elastic-agent's `output.default.ssl.certificate_authorities` then fail TLS
  against the re-issued ES certs — a fleet-wide ingest outage that no cookbook
  apply self-heals, because the gate reports "already done".
- **Why the needle cannot fix it**: the guard is a *content-shape* check, not a
  *value-drift* check. Detecting rotation needs a comparison against the
  authoritative SSM copy, which the skip_if deliberately avoids (it would put an
  `aws ssm get-parameter` on every apply's compile path).
- **First step**: add a value-drift check comparing the SSM cert's serial to the
  locally installed PEM's — fetch the param, `openssl x509 -noout -serial` on
  both, and re-fetch when they differ. Put it in the converge-time `execute`
  (where the existing `sudo diff -q` guard already lives) rather than the
  compile-time skip_if, and share one implementation between the two cookbooks.
  Delete this entry in the resolving commit.

## docs/rust.md — apply the estate-lens retro's sandbox-EPERM addendum (Low)

From the 2026-07-24 claude-md-audit removal verification: the estate-lens
session (eefe318b, 2026-06-22〜24 — the only real Rust session in 30 days)
produced a retro proposing a High-priority rust.md addition about the cargo
sandbox-EPERM pattern (cargo build/test hitting `Operation not permitted`
under the Claude Code command sandbox and the correct retry shape). It was
never applied, and the 2026-07 rules→docs demotion of rust.md must not bury
it.

- First step: pull the exact proposed text from the estate-lens retro
  (session eefe318b transcript or its retro output), verify the pattern
  against the current sandbox behavior once, then add the section to
  `cookbooks/claude-code/files/docs/rust.md`. Delete this entry in that
  commit.

## H2: MCP auth-proxy resource isolation (REVIEW NEEDED — post-cognee-decommission)

Status 2026-07-05: the cognee LXC/cookbook was decommissioned and the
surviving shared auth-proxy is `cookbooks/lxc-es-memory/files/auth-proxy/
proxy.py` (es-memory / v2 "memory" MCP). This item was written 2026-06-07
against the now-deleted cognee + ai-memory proxies and its earlier "audience
enforcement infeasible" conclusion PRE-DATES the es-memory rewrite — the
surviving proxy has since grown a v2 audience/subject enforcement matrix, so
the security posture must be RE-AUDITED before acting. FLAGGED for human review.

- Original concern: the auth-proxies pass `options={"verify_aud": False}` on
  the raw JWT signature-decode path (still present in the es-memory proxy at
  ~lines 134/147), i.e. the decode itself does not check audience.
- Surviving state: the es-memory proxy now DOES add a v2 audience/subject
  enforcement matrix at authorization time — `client_credentials` grants
  require `aud ∩ MEMORY_AUDIENCES` AND `client_id ∈ ALLOWED_CLIENT_IDS`
  (else 403 forbidden_audience); `authorization_code` claude.ai tokens carry
  `aud=[]` so aud is not required on that path. Whether this already closes
  the original cross-resource-reuse gap needs a fresh audit against the
  current code.
- WHY LOW: only `sh1@mercari.com` passes the consent ALLOWED_EMAILS gate, so
  the cross-resource-reuse gap requires a token leak AND a second principal
  to isolate from — the latter does not exist. Defense-in-depth gap, not a
  multi-tenant isolation failure.
- OPTIONS if a gap remains after the re-audit (each needs design):
  1. RFC-8707: make claude.ai send `resource=https://mcp.ohno.be/<svc>` and
     hydra/consent populate aud from `grant_access_token_audience`, THEN
     enforce `audience` in the proxy. Correct but largest scope.
  2. Scope-based isolation (mint/enforce a per-resource scope claim) — first
     confirm what `scope` a real claude.ai token carries.
  3. Keep as documented known-limitation.
- First step when revisiting: re-run the log-first probe against the
  es-memory proxy to confirm current claim shapes (aud/scope on a REAL
  claude.ai token vs the monitoring `client_credentials` prober), then decide
  whether the v2 matrix already suffices or option 1/2 is still wanted.

## auto-mitamae alert delivery — fired but unnoticed for 11 days

- Symptom: auto-mitamae ran silently dead 2026-05-19 → 2026-05-30 (cron
  renamed to `.DISABLED-by-praeco-incident`, never reverted). Fleet frozen
  at SHA 8bc55eb while origin/main moved to c77da39.
- Root of the *invisibility*: `AutoMitamaeApplyStale` and
  `AutoMitamaeOrchestratorStuck` alerts (cookbooks/lxc-monitoring/files/
  alerts/auto-mitamae.yml, `time()-last_apply_timestamp > 900`) EXIST and
  must have been firing the whole 11 days — but no one was notified. The
  rules are fine; the Alertmanager routing / notification pipeline is the gap.
- First step: confirm whether Alertmanager is deployed + has a working
  receiver (Slack/email/etc.). `ssh root@192.168.1.10 'pct exec 111 -- bash -lc
  "docker ps | grep -i alertmanager; cat ~/deploy/monitoring/alertmanager*.yml
  2>/dev/null"'`. If no Alertmanager, Prometheus alerts only show in the UI —
  decide a notification channel and wire it.
- Recovery already done (2026-05-30): cron re-enabled, fleet converged 18/18,
  ES RED cluster fixed; resilience hardening in setup PR #394.

## auto-mitamae self-deadlock — disabled cron cannot self-heal

- The monitoring apply that recreates `/etc/cron.d/auto-mitamae-orchestrator`
  is itself driven by that cron. Once disabled, nothing restores it.
- Intentional disables (`.DISABLED` rename) must NOT be auto-reverted, so the
  fix is detection, not auto-recreation: the staleness alert above + a working
  delivery pipeline is the correct backstop. No code change until alert
  delivery (above) is confirmed working.

## self-heal-loops headless auth — OAuth token expiry on pro-dev

- The self-heal cron loops (`cookbooks/self-heal-loops`, CT 104) run headless
  `claude -p` as shin1ohno using `/home/shin1ohno/.claude/.credentials.json`.
  If that OAuth token expires and needs interactive re-auth, the cron silently
  starts failing (logged in `~/.claude/logs/self-heal-{create,resolve}.log`,
  `rc!=0`).
- Reason: headless cron has no way to complete an interactive `claude` login.
- First step for permanent unattended operation: decide whether to switch the
  loops to an `ANTHROPIC_API_KEY` (set in the cron env / wrapper) instead of the
  interactive OAuth token — a billing/account-policy decision. Until then,
  monitor the loop logs and re-auth `claude` on pro-dev when a run logs an auth
  failure. Consider a node_exporter textfile metric off `…/self-heal-*.last`
  (last-run age) + a Prometheus staleness alert, mirroring SelfHealObserverStale.

## Automate elastic-billing-reader key rotation (AWS billing → Kibana)

- The `elastic-billing-reader` IAM user (home-monitor `pve-monitoring-aws-billing.tf`)
  uses a SINGLE static access key with no automated rotation. Shipped this way
  deliberately (read-only billing scope; matches the `elasticsearch-snapshot`
  precedent) plus a CloudTrail→SNS audit hook on key changes.
- Two coupled gaps to close when automating rotation:
  1. Adopt the `pve-bootstrap-ssm` primary/secondary 2-key harness
     (`aws_iam_access_key for_each = ["primary","secondary"]` + SSM alias swap +
     `lifecycle { ignore_changes = [value] }`) for `elastic-billing-reader`.
  2. The env file is WRITE-ONCE for VALUE changes. `cookbooks/elastic-agent/
     default.rb` `require_external_auth(skip_if: ...)` is now content-aware for
     key ADDITION (regenerates when `AWS_ACCESS_KEY_ID=` is absent on the
     billing host), but a rotated key VALUE will NOT propagate to CT 111 until
     `/etc/elastic-agent/elastic-agent.yml.env` is regenerated. Manual rotation
     recovery today: `rm /etc/elastic-agent/elastic-agent.yml.env` on CT 111 +
     `mitamae local pve/lxc-monitoring.rb`.
- First step: lift the primary/secondary `for_each` + rotation block from
  `home-monitor/pve-bootstrap-iam.tf` into `pve-monitoring-aws-billing.tf`, then
  add a value-drift check to the elastic-agent env-generation `skip_if`.

## mini always-on power: enforce durability across macOS updates (Low)

Status 2026-07-04: fixed the #603 root cause (mini idle-slept because
`mac-settings` deployed but never executed `pmset -c sleep 0`). Added an
idempotent enforce-execute in `cookbooks/mac-settings/default.rb`, so a
`darwin.rb` apply now converges the always-on power settings.

- RESIDUAL GAP: Macs are outside the auto-mitamae fleet (manual apply only), and
  a macOS **major update** can reset pmset. Between the reset and the next manual
  `darwin.rb` apply, mini would idle-sleep again and #603-class alerts would flap.
- First step when revisiting: decide the enforcement channel — either (a) bring
  mini under a periodic self-apply (a user-mode launchd timer running
  `mitamae local darwin.rb`, per `~/ManagedProjects/setup/.claude/rules/ruby.md` "automating mitamae"),
  or (b) a tiny standalone launchd job that re-asserts `pmset -c sleep 0` on load.
  (a) is broader but keeps mini current with all cookbooks; (b) is minimal.

## available-skills list diet — gws-*/recipe-*/persona-* occupy the session skill listing (Low)

From the 2026-07-06 claude-md-audit critic pass: the per-session available-skills
reminder lists ~100 deployed skills, dominated by the gws plugin families
(`gws-*`, `recipe-*`, `persona-*`). Their descriptions consume always-loaded
context the same way rules/ files did before #639/#666, but they were out of
scope for the rules diet.

- Reason deferred: the skills come from plugins/marketplaces, not the cookbook
  deploy lists — the diet mechanism is enabledPlugins scoping, not file deletion.
- First step: measure the actual byte share of the skill listing in a fresh
  session's system prompt, then trial-disable the `recipe-*`/`persona-*`
  families in `enabledPlugins` (keep `gws-*` operational skills) and confirm
  nothing in daily flows regresses.

## auto-memory stale review — Cognee-referencing memories post-#656 (Low)

From the 2026-07-06 claude-md-audit critic pass: project auto-memory dirs
(`~/.claude/projects/*/memory/`, 4 projects) contain entries written before the
Cognee retirement (#656) and the local-es-memory migration — e.g. zp-SHIN's
`loop-engineering-adoption` / `mcp-health-monitor-loop` reference Cognee
pipelines and the old local MCP ports.

- Reason deferred: memories are per-project and self-correcting on next touch
  (the stale-recorded-constraints rule shipped in #695 mandates write-back on
  reversal), but a proactive sweep shortens the stale window.
- First step: `grep -rliE 'cognee|cognify|8001|8002' ~/.claude/projects/*/memory/`
  and update or delete each hit, syncing MEMORY.md index lines in the same pass.

## remindd daemon — connection/idle-timeout hardening (Low)

From the adversarial review of the `remindd` daemon (cookbooks/remind, added with
the daemon PR). The daemon has no idle/read timeout and no max-concurrent-connection
cap, so a slow or silent LAN client (slowloris) can hold connections and starve the
accept loop. Deferred deliberately: the daemon is LAN-bound on a trusted home network
(Mac mini), single-user, so the exposure is a compromised/buggy LAN device only — out
of scope for the initial PR.

- Reason deferred: trusted-LAN posture makes this low-likelihood; the Hummingbird 2.x
  config API for read/idle timeout + max connections wasn't confirmed at implementation
  time and adding it unverified risked the build.
- First step: confirm the Hummingbird 2.x `Application`/server configuration knobs for
  idle/read timeout and max in-flight connections (swift-nio `ServerBootstrap`
  child-channel options surfaced via HB config), set a modest idle timeout (~30s) and
  connection cap in `cookbooks/remind/files/daemon/Sources/remindd/main.swift`, and
  add a slowloris probe to the verification steps.

## elastic-agent — two Linux defects that abort the whole apply (Medium)

Found by an adversarial review while making `linux.rb` converge on a keyless cloud
VM. The `sh1-cloud` profile now skips `elastic-agent`, so neither defect affects
that host any more — but both still stand for bare-metal / LXC Linux.

(Paths updated after #816 split the cookbook per-OS: both defects moved
verbatim into `cookbooks/elastic-agent/linux.rb`; old default.rb line numbers
no longer apply — locate by resource name.)

1. `execute "render elastic-agent.yml"`'s command string begins with
   `set -euo pipefail` (`cookbooks/elastic-agent/linux.rb`). mitamae runs
   `command` through `/bin/sh`, which is dash on Debian/Ubuntu, so this exits 2
   with `set: Illegal option -o pipefail`. Its `only_if` is
   `test -f <tmpl> && test -d /etc/elastic-agent`, i.e. it fires on any Linux host
   that already has the agent installed. The resource's own `not_if` carries a
   comment about dash lacking process substitution, so the dash constraint was
   known when it was written. The same class was already fixed in
   `cookbooks/{codex-cli,mcp,herdr,terraform}`. This is NOT the last unwrapped
   site — see the `lxc-elasticsearch / lxc-kibana / lxc-monitoring` entry below
   for nine more, and `ssh-keys` for a tenth.
2. The apt block in `linux.rb` (install prerequisites, add key, add repo,
   `apt-get update`, install, `apt-mark hold`) runs privileged commands with no
   `user` attribute and no `sudo` in the command string. Fine where
   `mitamae-runner` applies as root; fails on a Linux host applying as a regular
   login user. The darwin recipe (`darwin.rb`) already uses `user "root"` for
   its privileged installs, so the idiom is in place.

- Reason deferred: both fixes are one-liners, but neither is verifiable from the
  work Mac — the affected hosts (ES LXCs, bare-metal `pro`) are on the home LAN and
  unreachable from here (`ssh pro` → DNS failure, `neo.local` → connect timeout).
  Shipping an unverified change to the cookbook that feeds the monitoring cluster
  is worse than leaving a recorded defect. Also out of scope for the PR that
  surfaced it, which is about cloud-VM convergence.
- First step: from a host on the home LAN, run `./bin/mitamae local linux.rb
  --dry-run` and confirm whether the render resource is reached (that settles
  whether defect 1 is live fleet-wide or its `only_if` is simply unsatisfied). Then
  wrap the command in `bash -c '...'` per the herdr/terraform pattern, add
  `user node[:setup][:system_user]` to the six apt resources, and verify by
  dispatching `test-setup.yml` at `all-cookbooks`, which runs a non-sudo
  `./bin/mitamae local linux.rb` — exactly the non-root Linux profile defect 2
  fails under.

## ssh-keys — known_hosts keyscan is dash-fatal on Linux (Medium)

`cookbooks/ssh-keys/default.rb`'s step 5 builds `github_known_hosts_script` as a
heredoc beginning `set -euo pipefail` and passes it as a bare `command`
(`execute "register github.com host keys in known_hosts"`). mitamae runs `command`
through `/bin/sh`, which is dash on Debian/Ubuntu, so this exits 2 with
`set: Illegal option -o pipefail` and — no `ignore_failure` — aborts the rest of
`ssh-keys` and everything after it. Same class as the `elastic-agent` entry above
and as the already-fixed `cookbooks/{codex-cli,mcp,herdr,terraform}`.

Whether it is *live* is genuinely unclear and worth settling before touching it:
its `not_if` is `test -f known_hosts && grep -q '^github.com '`, so on any host
whose `known_hosts` already carries a github entry the resource never runs. A
Linux host that has been converging successfully for a long time may simply have
been seeded before the `pipefail` line was introduced.

The overlay's `cookbooks/gcp-ssh-keys` (kouzoh/zp-SHIN) deliberately carries its
own `bash -c`-wrapped copy of this script rather than reusing this one, and
records why in a comment — so the cloud box is unaffected either way.

- Reason deferred: unverifiable from the work Mac. The hosts that run `ssh-keys`
  past its AWS auth gate are the home-LAN LXCs and bare-metal `pro`, and neither
  resolves from here (`ssh pro` → DNS failure, `neo.local` → connect timeout).
  Changing the cookbook that distributes SSH keys to the whole fleet on an
  unverified hypothesis is the wrong trade.
- First step: on a home-LAN Linux host, `mv ~/.ssh/known_hosts{,.bak}` and run
  `./bin/mitamae local linux.rb --dry-run` to force the resource to be reached —
  that distinguishes "already seeded, never runs" from "live abort". If live, wrap
  in `bash -c '...'`; note the script uses `awk '{print $2}'`, which needs
  rewriting to `cut -d' ' -f2` under a single-quoted `bash -c` wrapper (bash would
  otherwise expand `$2` as a positional parameter), exactly as done in the
  overlay's copy.

## lxc-elasticsearch / lxc-kibana / lxc-monitoring — nine dash-fatal pipefail sites (Medium)

Found by auditing every commit of the 2026-07-30..08-02 window against its diff.
The `elastic-agent` entry above claimed to be the last unwrapped `pipefail` site
in the repo; it was already wrong when written (the very next PR recorded
`ssh-keys` as a second), and a full classification finds nine more. All nine are
the FIRST line of a bare `execute … command`, so on a Debian/Ubuntu host — where
mitamae runs `command` through `/bin/sh` = dash — they exit 2 with
`set: Illegal option -o pipefail`, and with no `ignore_failure` that aborts the
rest of the run:

| Site | Enclosing resource |
|---|---|
| `cookbooks/lxc-elasticsearch/default.rb:268` | `execute "render elasticsearch.yml"` |
| `cookbooks/lxc-elasticsearch/default.rb:294` | `execute "ensure elasticsearch.yml exists"` |
| `cookbooks/lxc-kibana/default.rb:330` | `execute "install Synthetics alerting (connector + Status + TLS rules)"` |
| `cookbooks/lxc-kibana/default.rb:346` | `execute "install process-liveness rules (~31 .es-query rules)"` |
| `cookbooks/lxc-kibana/default.rb:367` | `execute "install Stack Monitoring integration packages (EPM)"` |
| `cookbooks/lxc-monitoring/default.rb:430` | `execute "download dbip-city-lite GeoIP DB"` |
| `cookbooks/lxc-monitoring/default.rb:552` | `execute "fetch elastic CA cert from SSM"` |
| `cookbooks/lxc-monitoring/default.rb:586` | `execute "generate snmp.yml"` |
| `cookbooks/lxc-monitoring/default.rb:604` | `execute "ensure snmp.yml exists"` |

Firing conditions, read off the guards rather than assumed. The `render …` sites
are notify-driven and carry a `not_if` that diffs the freshly-rendered output
against the installed file, so a converged host skips them on every apply and
they fire the NEXT TIME THE TEMPLATE CHANGES. The `ensure … exists` sites carry
`only_if "… ! test -f <path>"`, so they fire on a FRESH LXC's first apply. That
is why a working cluster is not evidence against this: both classes are latent on
exactly the hosts that already converged.

`cookbooks/lxc-elasticsearch/default.rb:275-279` is the sharpest instance — its
comment correctly explains that mitamae evaluates `not_if` through dash and
rewrites the guard for dash compatibility, three lines below a `command` that
still opens with `set -euo pipefail`.

Detection: use `git grep -n pipefail`, NOT a `set -euo pipefail` literal. The
string `set -euo pipefail` does not contain the substring `-o pipefail` (the `-`
and the `o` are not adjacent), and `lxc-monitoring:430` uses the `set -uo
pipefail` variant, so both narrower patterns silently under-report. Classify each
hit by its enclosing construct before believing it: `cookbooks/gpg-backup:40,546`,
`cookbooks/s3-backup:56` and `cookbooks/lxc-pro-router:91` sit inside
`file … content` heredocs (shipped scripts with their own interpreter, not
mitamae `command` strings), and `cookbooks/tailscale:37` is inside a darwin-only
block where `/bin/sh` is bash in sh-mode and accepts the option. Those five are
NOT defects.

- Reason deferred: unverifiable and unfixable from this machine. All nine live on
  the home-LAN ES / Kibana / monitoring LXCs, which do not resolve from the cloud
  box (`air`, `ohnos-macbook` and `pro` all fail name resolution). Shipping an
  unverified change to the cookbooks that feed the monitoring cluster is the same
  trade already refused for the `elastic-agent` entry above.
- First step: from a home-LAN host, `pct exec <ct> -- /bin/sh -c 'set -euo
  pipefail'` to confirm dash rejects it on the actual template, then for each site
  wrap the command in `bash -c '...'` per the herdr/terraform pattern. Check each
  wrapped body for `awk '{print $N}'` first — bash eats `$N` as a positional
  parameter inside a single-quoted `bash -c`, so those need `cut -d' ' -fN`
  (same substitution the `ssh-keys` entry above records). Verify by touching a
  template input so the notify fires, and by applying to a fresh CT for the
  `ensure … exists` pair.

## sh1-cloud — every owner/group resource re-chowns on every apply (Low)

On the GCE OS Login box `sh1-cloud`, mitamae reports `owner will change from
'UNKNOWN' to 'sh1_mercari_com'` for EVERY resource carrying `owner`/`group`, on
every apply. The account resolves through NSS with no literal `/etc/passwd`
line, so mitamae cannot map the existing file's uid back to a name, always reads
`UNKNOWN`, always sees a mismatch, and always re-chowns. Observed 2026-08-05 on
a `COOKBOOK=zed-remote-server` apply, but it is NOT specific to that cookbook —
`cookbooks/host-profile`'s own `~/.setup_shin1ohno`, `profile.d` and `bin`
directories show the identical line in the same run, so this is repo-wide on
this host and predates the Zed work.

- **Impact today**: cosmetic and non-fatal. The chown succeeds (the files are
  already owned by that user), so nothing breaks — but no resource on this host
  is ever reported as up to date, which makes an apply's output unreadable for
  spotting a REAL change, and it is the same root condition that check 7 exists
  to catch in its failing form (`owner` without `group` → literal
  `chown <user>:UNKNOWN` → resource failure).
- **Trigger for it to become real**: any resource on this host whose chown
  target is NOT already correct (a root-owned path, a file created by another
  account). The chown then fails, and mitamae has no `ignore_failure`, so it
  aborts the whole run and silently skips every cookbook after it.
- **Reason deferred**: the fix is a repo-wide policy decision, not a local edit.
  `cookbooks/zsh` already omits `owner`/`group` on its `~/.bash_profile`
  resource for exactly this reason (comment at `cookbooks/zsh/default.rb`,
  `.bash_profile` block) — mitamae runs AS the target user, so a $HOME resource
  is correctly owned on creation and naming an owner buys nothing. Extending
  that to every $HOME-scoped resource touches dozens of cookbooks and needs a
  lint check to hold the line, which is its own PR.
- **First step**: count the blast radius with
  `git grep -c 'owner node\[:setup\]\[:user\]' cookbooks/ | wc -l`, then decide
  between (a) dropping `owner`/`group` on resources whose path is under
  `node[:setup][:home]` and adding a lint check that forbids re-adding them, or
  (b) leaving them and accepting the noise on NSS hosts. Note that (a) must NOT
  touch resources placed into system paths via `execute "sudo install ..."` —
  those legitimately name an owner.

## `/todo-collect` の Slack saved sweep が End of results に到達しない (Medium)

2026-08-17 の初回無人 run（sh1-cloud、`todo-collect-run.sh`）で `is:saved` を 6 ページ
（120 件）辿っても投稿日 2025-04 まで遡り続け、End of results 未到達で打ち切った。ledger には
truncated として残数不明のまま明記されている（silent cap は避けられている）。

- **前回記録との矛盾**: 2026-07-08 の ledger は「115 件フル sweep（6 ページ、End of results 到達）」
  と書いているが、同じ 6 ページで到達しないことが今回判明した。当時も打ち切っていた可能性が高く、
  「全件見た」という前提で候補を絞っていた分の取りこぼしが残っている。
- **なぜ現状の指示では閉じないか**: SKILL.md は「`cursor` を End of results まで辿る」と指示する
  だけで、saved の総数が MCP 検索の実用ページ数を超えるケースの打ち切り規則を持たない。毎日の無人
  run が同じ 120 件を再ページングし、末尾には永久に到達しない。
- **最初の一歩**: `is:saved` に `before:` を組み合わせた時間窓分割ページング（saved は保存状態の
  リストなので、投稿日の窓を古い方へずらしながら各窓で End of results を確定させる）を実測する。
  実用ページ数の上限が窓分割でも越えられないなら、「候補化は直近 N 日の投稿に限り、それ以前は毎回
  truncated 残数つきで明記する」を SKILL.md に明文化する。完了条件: sweep が End of results に
  到達する、または打ち切り規則が SKILL.md に明記され ledger に残数が出る（このエントリは対応
  コミットで削除）。

## ledger.md が全時代を 1 ファイルに抱え、承認待ちキューが履歴に埋もれる (Medium)

`~/.claude/todo/ledger.md` は日次 collect と週次 reconcile が追記する単一ファイルで、
2026-08-17 の 2 run だけで 256 行のうち約 120 行を占めた。両 SKILL.md は「前回 run の
disposition を参照して再列挙を省略」と指示しているため、1 run あたりのコンテキスト費用が
**open backlog ではなく全時代のファイルサイズ**に比例して増える。

- **なぜ prose の規律では閉じないか**: 承認待ちキュー（無人 collect が書く inferred 候補）が
  履歴と同じファイルに同居している。「reconcile は candidate セクションを消さない」という
  不変条件を #899 と kouzoh/zp-SHIN#163 で明文化したが、これはモデルが守るべき規則であって
  構造的な保証ではない。ファイルが 1 本である限り、全文再生成の誘惑は残る。
- **最初の一歩**: `~/.claude/todo/runs/<date>-<loop>.md`（write-once の実行ログ、自動 run は
  読み返さない）と `~/.claude/todo/candidates.md`（open な候補のみ。承認・却下で行が消えるので
  サイズは O(open)）に分割する。影響範囲は SKILL.md 2 本 + overlay の prompt 2 本 + runner の
  `LEDGER` 定数（+ 既存 ledger.md を 1 回だけ分割する移行スクリプト）。
- 緊急ではない（現在 256 行）。数千行に達する前に着手する。完了条件: 候補キューが open 件数に
  比例するファイルに分離され、reconcile が履歴を読まずに 1 サイクル完走する（このエントリは
  対応コミットで削除）。

## herdr — bump past 0.8.0 once a stable ships the oversized-frame render fix (Low)

herdr 0.8.0 (pinned in `cookbooks/herdr/default.rb`) silently stops rendering an
attached client when the terminal reports a large size: the SemanticFrame render
exceeds the server's hardcoded 2MB frame cap and the server drops every frame
(`WARN herdr::server::headless: skipping oversized frame … claimed=3494423
max=2097152`), so `hr` looks dead while the handshake, input events, and sound
notifications all still flow. Observed on sh1-cloud 2026-08-18T01:31Z when a
mosh client reported 1300×383 cells; rendering resumed by itself once the size
dropped back to 185×63. Upstream: herdrdev/herdr#2670 (closed), fixed by #2675
"compact large terminal redraws" (plus #2829, which makes the headless terminal
size configurable) — both in preview-2026-08-17, neither in any stable (latest
stable = v0.8.0, the pinned version).

- Reason deferred: the fix exists only in a preview build. The cookbook pins
  stable releases by sha256, and swapping the server binary kills every running
  pane (agents included), so waiting for the next stable is the right trade.
  Workaround when it recurs: resize the terminal / reset font zoom back to
  normal — frames resume immediately; do NOT restart the server.
- First step: when a stable newer than 0.8.0 appears
  (`gh api repos/ogulcancelik/herdr/releases/latest --jq .tag_name`), confirm
  its notes include #2675, recompute the per-target sha256s per the comment in
  `cookbooks/herdr/default.rb`, bump `herdr_version`, and restart the server at
  a moment when no agent panes are active. Delete this entry in the resolving
  commit.

## Vector drops 94% of RTX DHCP lease events on the floor (Low)

`transforms.parse` Stage 3 in `cookbooks/lxc-monitoring/files/vector.toml` matches
`\[DHCPD\] (?P<dhcp_event>Extends|Assigns|Releases) (?P<lease_ip>[\d.]+): (?P<mac>[0-9a-f:]+)`
— the event word has to follow `[DHCPD] ` immediately. HND's RTX1210 puts the
serving interface in between and ITM's RTX830 does not:

```
[DHCPD] LAN1(port4) Extends 192.168.1.69: 9c:58:84:16:a5:b2   <- hnd, unparsed
[DHCPD] Extends 192.168.1.156: 12:e6:07:0f:e1:ec              <- itm, parsed
```

- **Measured 2026-08-23**: 474 `[DHCPD]` events in 24h, of which only 30 carry
  `dhcp_event` — every one of those 30 is from itm. All 444 hnd lease events land
  with no `dhcp_event` / `lease_ip` / `mac`, so "which MAC held which lease when"
  is unanswerable for the site that actually has the device churn. Found while
  verifying the IPv6 parser work in PR #915; unrelated to it and older than it.
- **First step**: allow an optional interface token —
  `\[DHCPD\] (?:(?P<dhcp_interface>\S+) )?(?P<dhcp_event>Extends|Assigns|Releases) ...`
  — and add `dhcp_interface` to `logs-rtx-mappings.json` if it is captured, since
  that mapping is `dynamic: strict` and a new field is otherwise a whole-document
  rejection. Cover both spellings with a `[[tests]]` case each; the harness and
  its `vector test` invocation are already in the file.

## pve-host holds the ULA /64 on both bridges, so v6 source selection is asymmetric (Low)

`cookbooks/pve-host` now pins `fd97:b085:767d::10/64` on vmbr0 so that
`pve.home.local`'s AAAA resolves to an address this host actually answers. But
vmbr1 already autoconfigures an address from that same /64 (it has
`forwarding=0`, so it honours the RTX lan1 RA), which leaves two connected
routes to `fd97:b085:767d::/64`:

```
fd97:b085:767d::/64 dev vmbr0  proto kernel   <- added by this cookbook
fd97:b085:767d::/64 dev vmbr1  proto ra       <- pre-existing SLAAC
```

- **Why it is not broken today**: both NICs sit on the same L2 (192.168.1.0/24 —
  vmbr0 = enp25s0, vmbr1 = enp12s0, and the CTs are on vmbr0), so frames reach
  their destination either way. Inbound to `::10` always lands on vmbr0, which
  is all the AAAA needs.
- **What is actually wrong**: pve's SOURCE address selection for ULA
  destinations can pick vmbr1's SLAAC address, so a flow this host originates to
  a CT's ULA leaves with a source on the other bridge. That is invisible until
  something filters or logs on source address, and it makes `::10` a
  receive-only identity rather than this host's v6 identity on that LAN.
- **Why the obvious fix was not taken**: dropping vmbr1 to `accept_ra=0` would
  also drop this host's only v6 default route (it is learned on vmbr1,
  `proto ra`), taking away hypervisor v6 egress. The dual-homing itself predates
  this change — `cookbooks/arp-flux` exists because the same two bridges already
  collide on IPv4.
- **First step**: decide whether vmbr1 should be on this LAN's ULA /64 at all.
  Probe what actually depends on vmbr1's v6 (`ss -6 -tunap` on the PVE host, and
  which source the default route picks with
  `ip -6 route get <a CT ULA>`); if nothing needs it, add `token`/`accept_ra`
  handling so only vmbr0 carries the /64 while vmbr1 keeps just the default
  route. Verify with `ip -6 route get` returning `src fd97:b085:767d::10`.

## CT 103 (housekeeping) runs, but still has no working job (Medium)

**Started 2026-08-26.** The blocker was `mp0` binding `/mnt/data/obsidian-vault`
from the host while that directory did not exist, so `lxc.hook.pre-start`
failed. Creating it (`install -d -m 0755 -o 100000 -g 100000` -- 100000 because
the CT is `unprivileged: 1`) and `pct start 103` fixed it. The container is
`running`, `systemctl is-system-running` reports `running` with no failed units,
the bind-mount appears inside as `root:root` and is writable, and the permanent
`HTTP 500 - Reason: no options specified` diff on
`proxmox_virtual_environment_container.lxc["housekeeping"]` is gone
(`terraform plan` -> no differences).

**Neither of its two services does anything yet.** That was true while it was
stopped and it is still true now:

- `obsidian_file_sync` — observed live at 2026-08-26 18:24:53: the timer fires
  and exits at the `rclone listremotes` guard, because `~/.config/rclone/` is
  empty (no `rclone.conf`, no remotes at all). No `~/.cache/rclone/bisync/`
  state exists, so `rclone bisync` has still never run. Its source is
  `${HOME}/obsidian` (`/root/obsidian`, empty) -- NOT the `mp0` path, so the
  mount and the sync source point at different directories.
- `s3-backup` — two independent reasons, not one. There is no
  `~/.config/s3-backup/config` (only `config.sample`), so the script would die
  at "S3_BUCKET is not configured". AND `s3-backup.timer` is `disabled` /
  `inactive` and absent from `timers.target.wants/`, so it would not fire even
  with a config. `cookbooks/s3-backup/default.rb:443` says
  "systemctl --user requires D-Bus session, cannot run in mitamae context" and
  leaves enabling to a manual step that has not happened in ~4 months.
  **That comment is wrong**: the sibling `cookbooks/obsidian_file_sync`
  (`default.rb:136-142`) arms its timer from mitamae with exactly that command
  and it works -- `obsidian-sync.timer` is armed and firing.

**Before configuring the `icloud:` remote, add a guard.** `obsidian_file_sync`
runs `rclone bisync` (bidirectional) and `mkdir -p`s its source if absent. The
local side is empty, so pointing it at a populated remote is a
deletion-propagation hazard. It is harmless today only because no remote is
configured -- that accident is the only thing standing in for a guard. Replace
it with a deliberate one (`--resync` on first run, `--max-delete`) rather than
just filling in `rclone config`.

**First step**: decide whether this CT still has a job. If the vault now lives
elsewhere, deleting the CT and both cookbooks is more honest than repairing a
sync that was never wired up. If it should work, three things are missing and
all three are needed: the `icloud:` remote (with the bisync guard above), a real
`s3-backup` config (S3_BUCKET + GPG_RECIPIENT), and an `execute` in
`cookbooks/s3-backup` that enables its timer the way the obsidian cookbook does.
Also reconcile `mp0` with `SOURCE_DIR` -- they currently disagree.

## Nothing catches a keeper file that is imported but never deployed (Medium)

`memory-keeper-reconcile.service` on CT 119 crashed on every tick from
2026-08-26 19:26 to 2026-08-29 16:00 with `ModuleNotFoundError: No module named
'merge_rules'`. PR #895 added `merge_rules.py` and an `import merge_rules` to
both `reconcile.py` and `consolidate.py`, but not the corresponding entry in the
explicit deploy map in `cookbooks/lxc-es-memory/default.rb`. The PR that adds
this entry restores the missing line; two mechanisms that should have caught it
did not.

- **`bin/lint-cookbooks` check 6 is deploy-list drift, but only for
  `claude-code`** (`files/{rules,docs,workflows,agents}/`). Every other cookbook
  that ships a hand-maintained `{src => dest}` map — `lxc-es-memory`'s keeper
  python being the one that broke — has no equivalent check. The generic form is
  cheap: for a cookbook whose `files/<dir>/` holds python, parse the top-level
  `import`/`from` statements of each deployed module and FAIL when a sibling
  module they name is absent from the map.
- **`memory-keeper-health.sh` reports `memory_keeper_raw_backlog` and
  `memory_keeper_stats_age_seconds`, neither of which moved when the unit died.**
  Backlog was 0 throughout (nothing was arriving), so the fleet looked healthy
  while reconcile had never once completed. `stats_age` was worse than blind: its
  extraction grep could never match, because `docvalue_fields` with
  `format: epoch_millis` returns a QUOTED string, so the metric had been pinned
  to its `-1` sentinel since the day it was written. That grep is fixed
  separately; what remains is that a permanently-failing oneshot with an empty
  queue still looks identical to a healthy idle one, because no metric carries
  the unit's exit status.

**First step**: add the import-vs-deploy-map check to `bin/lint-cookbooks` as a
FAIL-tier check (it is mechanical and has no false positives — a named sibling
module either is in the map or is not), and emit
`memory_keeper_reconcile_last_exit_code` from `memory-keeper-health.sh` via
`systemctl show -p ExecMainStatus memory-keeper-reconcile.service` so a dead
tick is visible with an empty queue. Delete this entry in the resolving commit.
