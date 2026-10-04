# TODO

## Any fleet LXC can read an account-wide GitHub push key, and setup main is unprotected (High)

- **Failure class**: a compromise of ONE fleet LXC becomes a fleet-wide root
  compromise. Every fleet host shares the `pve-bootstrap-ssm` identity, which
  reads every device key under SSM `/ssh-keys/devices/*` and may decrypt them
  (home-monitor `pve-bootstrap-iam.tf:108-124`). Each of those keys is
  registered as a GitHub *user* SSH key (`ssh-devices.tf:117`,
  `github_user_ssh_key`), i.e. push access to every repository of the account.
  setup's `main` has no ruleset and no branch protection (probed 2026-09-28:
  `gh api repos/shin1ohno/setup/rulesets --jq length` → 0,
  `…/branches/main/protection` → 404 "Branch not protected"), and auto-mitamae
  converges every setup `main` SHA onto the fleet as root within minutes.
- **Why now**: found by the adversarial review of the ai-memory extraction
  ADR draft (`docs/adr/0013-ai-memory-own-repo.md`). A new `shin1ohno/ai-memory`
  repo created with default settings would inherit the same exposure for
  CT 119. It is outside that ADR's scope, so it is tracked here.
- **Decided (2026-09-28)**: setup `main` keeps no ruleset (ADR 0013 Decision
  10), so the fix is on the key side. The F1 adversarial review
  (`~/.claude/plans/ai-memory-extraction-2026-09-27/review-f1.md`) chose
  per-host read scope plus separate GitHub keys, not deploy keys: the shared
  principal reads only `/ssh-keys/devices/*/public`; only the four
  interactive dev machines (pro-dev's user, air, neo, mini) get a GitHub key,
  generated apart from their login keys under `/ssh-keys/github/<k>`; the 24
  `github_user_ssh_key.device` registrations go; service LXCs leave the
  managed `authorized_keys` sections and their seed lines are removed on
  every CT; the keys that stay trusted are rotated. The canary (CT 104 root)
  currently fetches setup over SSH with `tf-device-pro` through a blanket
  `insteadOf`, so that is fixed before any key is withdrawn.
- **First step**: F2 (Linear SH1-63, home-monitor, apply with the user's
  permission) Phase 1 — the additive Terraform (C1-C4, C10 in review-f1.md
  §3.1); then F3 (SH1-64) in setup (ssh-keys role split, real-read gate,
  `insteadOf` retirement on CT 104 root, pro-dev and mini, seed-line removal
  after the user approves the target list).

## CT 104 root holds the admin (`sh1admn`) static key (Medium)

- **Failure class**: an unattended fleet LXC carries admin AWS credentials,
  against this repo's rule that fleet LXCs never get `sh1admn` keys (CLAUDE.md,
  AWS profile resolution). A compromise of the canary reaches admin/billing.
  The comment at `cookbooks/memory-mirror/default.rb:129-130` assumes the
  opposite.
- **Why**: found as V-2 by the F1 review verifier (review-f1.md §5), outside
  F1's scope.
- **First step**: on CT 104, list `aws configure list-profiles` and which
  cookbook or bootstrap placed the `sh1admn` profile for root; decide whether
  root needs it at all (the interactive user already has admin), then remove
  it through the owning cookbook, not by hand.

## mitamae-runner's role-name check lets `..` and a leading `/` through (Low)

- **Failure class**: `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:79`
  validates the role path with a regex that accepts `..` segments and an
  absolute path, so the forced-command entry could be pointed at a recipe
  outside `pve/`. The caller is the orchestrator's key, so this is defence in
  depth, not an open hole.
- **Why**: X-1 from the F1 review (review-f1.md §5).
- **First step**: tighten the regex to `^pve/lxc-[a-z0-9-]+\.rb$` (plus the
  PVE host's entry), with a run-state scenario that feeds `../x.rb` and
  `/tmp/x.rb` and expects a refusal.

## The orchestrator key's `from="192.168.1.76"` may be spoofable on the LXC bridge (Low, unverified)

- **Failure class**: `pve-firewall` is disabled, so another LXC on the same
  bridge might claim 192.168.1.76 and satisfy the `from=` restriction on the
  orchestrator's forced-command key [unverified].
- **Why**: X-2 from the F1 review (review-f1.md §5, §6 U-13).
- **First step**: on the PVE host read `pve-firewall status` and whether any
  `/etc/pve/firewall/*.fw` sets `ipfilter`; if not, enable per-CT `ipfilter`
  for the fleet CTs before relying on `from=`.

## Every LXC can read the orchestrator private key and the monitoring secrets (Medium)

- **Failure class**: home-monitor's `monitoring_lxc_ssm_read` policy, meant for
  CT 111 (monitoring), is attached to the shared `pve-bootstrap-ssm` user
  (`pve-monitoring-lxc.tf:185-195,271-273`), so every LXC can read
  `/ssh-keys/orchestrator/private` and the CT 111-only secrets (Grafana admin
  password, the PVE API token). One LXC compromise yields the key that pushes
  mitamae runs to every host.
- **Why**: DEPLOYKEY-8 from the F1 review (review-f1.md §5); kept out of F2 so
  the key fix stays small.
- **First step**: give CT 111 its own IAM principal (seeded like
  `bin/bootstrap-lxc-creds` does, but not copied to other CTs), move the
  CT 111-only entries of `monitoring_lxc_ssm_arns` onto it, and leave only
  `/ssh-keys/orchestrator/public` and `/ssh-keys/break-glass/public` on the
  shared user (every LXC's auto-mitamae-target reads those two).

## mac-block-tracker holds the router's shared admin password and trusts a spoofable pi (Medium)

- **Failure class**: `cookbooks/mac-block-tracker` runs unattended on pro-dev
  with an IAM key that reads `/rtx-routers/hnd/admin_password`, i.e. full
  control of rtx-hnd, and it decides what to write from an AirPlay `pi` that
  any LAN device can claim. The 2026-10-02 adversarial review's three blockers
  (router key left behind on the fallback path, password sent without waiting
  for `Password:`, TOFU host key) are fixed, and the write path now needs the
  ip/MAC pair in the router's DHCP table, two consecutive sightings, a reject
  pair on 17/18 and at most 3 moves a day. What remains: (1) a device that
  changes its own MAC to a family member's private MAC and answers with ann's
  pi can still get that MAC blocked at night (mail on every move is the only
  signal); (2) the admin password is the router's single shared one, so the
  key is as strong as full router control; (3) a unit-level failure before
  the script runs (missing `aws.env`, ExecStart error) is not mailed, only
  visible as a failed unit.
- **Why**: found by the adversarial review of the tracker (items 3, 15, 20);
  out of scope for the first version, which the user wanted live before ann's
  next rotation (about 10-14).
- **First step**: probe whether RTX1210 Rev.14.01 accepts a separate login
  user with `administrator=2` (admin without the shared password) by reading
  `login user ?` / `user attribute ?` on the router; if it does, give the
  tracker its own user and key and drop `admin_password` from the IAM policy.
  For (3), add `OnFailure=` pointing at a oneshot that publishes to
  home-monitoring-alerts.

## bin/converge's doctor gate, sentinel, and dry-run branch have known correctness gaps (Medium)

- **Failure class**: the ADR 0012 `bin/converge` single-entry wrapper (doctor →
  bootstrap → entry, INCOMPLETE via exit 3) has three real bugs and two design
  gaps found by the ADR 0011/0012 adversarial design review
  (`docs/adr/0011-0012-review-design.md`, G1/G2/G3/G5/G6):
  - (G1) `bin/doctor` always STS-checks a FIXED profile
    (`aws-config.json`), but `ssh-keys` auto-selects any valid profile at
    TTY-time. A host whose only valid profile has a different name passes
    ssh-keys' own gate but fails doctor's pre-check and never reaches entry —
    doctor can block a legitimate first-time auth instead of enabling it.
    Also, `awscli`'s PATH addition (`/usr/local/bin`) only takes effect inside
    the child process that installed it; the parent wrapper shell's `PATH`
    does not see it, so doctor's `aws` presence check can still fail
    immediately after a successful install.
  - (G2) `record_gate_event` records only `tool`/`reason`, with no
    required/optional distinction. SSM permission shortfalls are WARN, gh
    auth is WARN, and a non-TTY `auth_unavailable` can return without ever
    writing a sentinel — so "a required gate did not run" is NOT something
    the sentinel + doctor combination can currently detect, even though the
    ADR's Decision 3 describes exit 3 as covering exactly that case.
  - (G3) `bin/converge`'s `rm -f` (clearing the previous success sentinel)
    executes even under `--dry-run`, and gate-report's write is an `execute`
    resource that dry-run never reaches. `--dry-run --skip-doctor` returning
    0 therefore reports "converged" while having just deleted the evidence of
    the PREVIOUS real convergence.
  - (G5) fleet hosts (`pve/lxc-*.rb`) do not participate in this completion
    contract at all — `bin/bootstrap-lxc-creds` only places a credentials
    file (does not install awscli), and the auto-mitamae runner records
    success/verified-SHA off mitamae's exit code alone, with no sentinel or
    doctor-equivalent check.
  - (G6) the ADR's Decision 2 states bootstrap carries no host configuration;
    in fact `bootstrap.rb` → `functions` → `host-profile` creates
    `~/.setup_shin1ohno` and friends, and the darwin `awscli` branch removes
    an existing Homebrew awscli install and registers a profile file — both
    BEFORE entry's own host-type validation (e.g. the bare-metal container
    refusal in `linux.rb`) runs.
- **When each triggers**: G1 on any host whose valid AWS profile name differs
  from the one hardcoded in `aws-config.json`, or immediately after a fresh
  `awscli` install in the same wrapper invocation; G2 whenever a truly
  required gate hits `auth_unavailable` in a non-TTY run; G3 on any
  `--dry-run` invocation following a real prior convergence; G5 on any new
  fleet LXC's first bootstrap; G6 whenever bootstrap runs against a host type
  entry would have rejected.
- **Why not fixed in the PR that found them**: each needs a real redesign —
  G1/G2 need doctor's gate model reworked to mirror entry's own auth-selection
  contract and to carry required/optional + machine-readable outcome, not a
  one-line patch; G3 needs the dry-run branch to skip both the sentinel
  deletion and the completion judgment; G5 needs an independent fleet
  migration condition (verify fresh-LXC bootstrap, don't advance verified-SHA
  on an incomplete run) that does not disturb the runner's existing flock /
  SHA+role verification / forced-command constraints; G6 is a documentation
  correction already applied to ADR 0012 plus a reordering (host-type
  validation before bootstrap) that is next-step, not this PR's scope.
- **First step**: for G3 (cheapest, most likely to bite first), guard the
  sentinel `rm -f` and the gate-report write path on `$DRY_RUN` in
  `bin/converge`, and add a harness case that runs `--dry-run` after a
  simulated prior success and asserts the sentinel is unchanged. Then work
  G1/G2 (doctor gate model) and G5 (fleet migration condition) as separate
  changes, each starting from the exact repro in
  `docs/adr/0011-0012-review-design.md`. Delete this entry in the resolving
  commit.

Status 2026-09-20: G3 is still unguarded. On origin/main `bin/converge:62` is
a bare `rm -f "$sentinel"`, and `--dry-run` only assigns `dry="--dry-run"` at
:32 — the sentinel removal sits outside any dry-run branch, so `--dry-run
--skip-doctor` still deletes the evidence of the previous real convergence.
`git log --grep=converge` on main has #973 (the PR that filed this) as its
newest converge commit, so none of G1/G2/G3 has been touched since.

## bin/check-memory-v2-manifest's CI-recipe and import-line scanners have known blind spots (Medium)

- **Failure class 0 (`bin/check-memory-v2-manifest`'s file-existence loop)**: the
  MANIFEST-vs-directory listing pipes `find ... | sed | sort` into a
  `while IFS= read -r f` loop and then `grep -qxF "$f"` per line. A committed
  filename containing a literal newline is split into two lines by the loop
  and matched against the MANIFEST as two separate (and possibly already-listed)
  entries, so it can pass without ever being individually verified. Fixing this
  needs a NUL-delimited (`find -print0`) pipeline throughout, which the rest of
  the script (associative dirname/cp logic) would also need to move to. Real-
  world risk is low — this only matters for a developer-committed filename, not
  external input — so it is deferred alongside D2/D4 below rather than folded
  into the symlink-rejection fix this PR did ship (review D3, the symlink half).

- **Failure class 1 (audit condition 5, `bin/audit-cookbook-reachability`)**: the
  CI-embedded-recipe heredoc scanner reads raw workflow-file lines and requires
  the `.rb` filename and the `<<` heredoc marker to appear on the SAME raw
  line. A YAML folded/literal block scalar (`run: >` or `run: |`) can put the
  `cat > x.rb` and the `<<'EOF'` marker on different physical lines while still
  being one shell command after YAML decoding — that heredoc's
  `include_cookbook` lines are never scanned, silently recreating exactly the
  stale-include blind spot ADR 0010 exists to close. Surfaced by the ADR 0010
  diff review (D2, `docs/adr/0010-review-diff.md`).
- **Failure class 2 (`bin/check-memory-v2-manifest`'s server.py import check)**:
  the `grep -hE '^(from|import) (mcp|starlette|httpx|uvicorn)\b'` extraction
  reads matching lines textually, not via Python's grammar. A multi-line
  `from mcp.server.fastmcp import (` breaks (continuation lines are not
  extracted, so the piped `python3 -I -` sees a `SyntaxError`), and any
  additional statement appended to a matching import line executes too
  (`import mcp; print("EXTRA_STATEMENT_EXECUTED")` runs the print). The current
  single-line-import shape in `server.py` is unaffected, but the checker's
  "import time ES を叩かない" guarantee does not extend to a differently
  written import going forward. Surfaced by the same diff review (D4).
- **When each triggers**: D2 the next time a CI real-install step is authored
  with a folded/literal `run:` block instead of the canonical
  `cat > x.rb << 'EOF'` form; D4 the next time `server.py`'s mcp/starlette
  imports are rewritten as multi-line or a statement is appended to one of
  those lines.
- **Why not fixed in the PR that found them**: both need a real re-implementation,
  not a one-line patch — D2 needs the workflow YAML parsed with Psych so the
  `run:` value is recovered before the heredoc scan runs (turning condition 5
  into "scan the decoded script text", not "scan raw file lines"); D4 needs
  `ast.parse` to select the module-level `Import`/`ImportFrom` nodes that name
  the target packages, instead of a textual grep. Both are a different shape of
  checker than the ones the ADR 0010 PR shipped.
- **First step**: for D2, add a `Dir["#{REPO_ROOT}/.github/workflows/*.{yml,yaml}"].each { |wf| YAML.safe_load_file(wf) }`
  pass that walks `jobs.*.steps[].run`, and run the existing heredoc-scan regex
  against each decoded `run:` string (split on `\n`) instead of `File.foreach`
  over the raw file; keep the existing raw-line scan as a fallback for any step
  that is not a heredoc at all. Add the ADR 0010-review-diff.md D2 example as a
  regression case. For D4, replace the `grep -hE` extraction with a small
  `python3 -c 'import ast, sys; ...'` that parses `server.py`, walks
  `ast.iter_child_nodes(tree)` for `ast.Import`/`ast.ImportFrom` nodes whose
  module is one of mcp/starlette/httpx/uvicorn, and re-emits each as a
  standalone one-line import statement for the existing `python3 -I -` pipe.
  Delete this entry in the resolving commit.

Status 2026-09-20: D2 is unimplemented. `git grep -ic yaml origin/main --
bin/check-memory-v2-manifest` = 0, so the scanner still does no YAML parsing
at all and cannot walk `jobs.*.steps[].run` (positive control:
`REPO_ROOT|manifest` = 17 hits in the same 7602-byte file, so the grep is
reading it).

## bin/check-host-configs's static-analysis checks have coverage gaps a well-formed config can exploit (Medium)

- **Failure class**: the FAIL-tier checker added for ADR 0011 (`bin/check-host-configs`)
  reads Prometheus's `node-*` scrape jobs and the FLEET table with regexes and
  string matching rather than a structural parser, so it can report OK against
  inputs its own design intends to catch. Surfaced by the ADR 0011/0012
  adversarial design review (`docs/adr/0011-0012-review-design.md`, F1/F2/F4):
  (F1) the regex reads only the FIRST `- targets:` entry and the FIRST `host:`
  label per job, so a second static target or a re-quoted job name is invisible
  to the checker; (F2) any job whose target the checker cannot parse as IPv4 is
  treated as "DNS" and passed on host-label presence alone, without validating
  the target string or its port; (F4) the FLEET extraction depends on the exact
  quoting style of the Ruby literal (`'ip' => '...'`  vs a re-quoted or
  reformatted line), so a changed IP that also changes quoting style drops out
  of the extracted set instead of being compared.
- **When it triggers**: any future edit to `prometheus.yml` that adds a second
  static target to an existing job, uses double quotes on a job name, points a
  job at a wrong host while keeping its label, or reformats the FLEET hash
  literal in `cookbooks/host-profile/default.rb` — the checker stays green
  while the drift it exists to catch goes uncaught.
- **Why not fixed in the PR that found them**: closing F1/F2/F4 needs the
  checker to parse the real Prometheus YAML (Ruby's stdlib `YAML` module)
  rather than regex over lines, plus a target-syntax validator and an explicit
  DNS-name allowlist keyed by policy (not by host-label presence) — a
  structural rewrite of the checker, not a one-line patch. F3 (the
  `config/host-policy.json` exception schema accepts an empty `reason` and
  conflates job-name aliases with host-label aliases) needs a typed exception
  schema. All four need review before landing so the rewritten checker does
  not itself acquire new blind spots.
- **First step**: rewrite the Prometheus-side read using `YAML.safe_load_file`
  and walk `scrape_configs[].static_configs[].targets` exhaustively (not just
  index 0), FAILing on any static target the walk cannot classify as IPv4 or an
  explicitly policy-allowlisted DNS name. Add the F1/F2/F4 examples from
  `docs/adr/0011-0012-review-design.md` as regression fixtures before touching
  the implementation. Delete this entry in the resolving commit.

Status 2026-09-20: unchanged. `safe_load_file` = 0 hits in
`bin/check-host-configs` (4695 B) while the positive control `prometheus` = 11
hits, so the Prometheus-side read is still the regex / index-0 form rather
than an exhaustive `scrape_configs[].static_configs[].targets` walk.

## auto-mitamae runner has no remote-side apply deadline; a stuck mitamae holds the flock and the canary gate (Medium)

- **Failure class**: orchestrator.sh bounds only the LOCAL `ssh` with `timeout 300`.
  The remote `mitamae-runner` keeps running after the ssh session drops, and
  any child it spawned inherits fd 9 (the `/var/lock/auto-mitamae.lock` flock).
  A mitamae that never exits (e.g. an ES node blocking on a RED-cluster wait)
  therefore answers `lock_held` on every later cycle. Since ADR 0009 the canary
  gate HOLDS the fleet on `lock_held` (it used to fall through and ship an
  unvalidated sha), so a stuck canary now stops rollout until an operator
  intervenes — visible via `AutoMitamaeCanaryHeld` (30m warning). Surfaced by
  the ADR 0009 adversarial design review (F4, `docs/adr/0009-review-design.md`).
- **When it triggers**: an apply on the canary that outlives the orchestrator's
  300s ssh window and does not finish on its own.
- **Not done in ADR 0009's PR**: choosing a runner-side deadline is a fleet
  load / correctness trade-off (a fresh LXC's first converge legitimately runs
  long) and the pre-existing behaviour is unchanged by the PR.
- **First step**: measure real apply durations from
  `auto_mitamae_last_apply_duration_seconds` (p99 per host over 30d), then wrap
  `./bin/mitamae local` in `timeout --kill-after=30s <N>` with N above that p99,
  recording `mitamae_timeout` as a distinct `last_attempt_status` / runner status
  so the gate treats it as fail (retry), not hold. Add a harness case where the
  stub sleeps past the deadline.

Status 2026-09-20: no deadline yet. `git grep -n 'kill-after|mitamae_timeout'
origin/main -- cookbooks/ bin/` returns 0 hits, so `./bin/mitamae local` still
runs unbounded and `mitamae_timeout` exists as a `last_attempt_status` value
nowhere in the tree.

## Network fault detection covers thresholds only; the baseline-comparison half is unwritten (Medium)

`expected-network-signals.json` (#948) ships ten `.es-query` rules, all of the
"count crossed a fixed threshold" shape. That catches a device going silent or a
radio crashing, but not the class of fault the 2026-09 6GHz investigation
actually turned up, where nothing is absent and nothing crashes — a client
reconnecting far more than it used to, band steering firing in a burst, a
config change silently disabling CCE. Those only show against the same clock
window on preceding days, and no rule computes that today.

- **Why it was split off**: the DSL rules carry no risk of Kibana rejecting the
  rule body, so #948 could prove the whole path (rule -> observer ->
  `self-heal-state` -> issue) without betting on `searchType: esqlQuery` being
  accepted at creation time. That acceptance is the one thing still unverified;
  the rule type and the Basic license were confirmed.
- **The comparison itself is proven.** Run against live ES, this returns zero
  rows when healthy and one row on a real excursion, which is exactly what an
  `.es-query` rule needs:

  ```esql
  FROM logs-wlx-default
  | WHERE device == "wlx323" AND code == "0113"
  | EVAL d = DATE_TRUNC(1 day, @timestamp), h = DATE_EXTRACT("hour_of_day", @timestamp)
  | WHERE h >= 13 AND h < 16
  | STATS c = COUNT(*) BY d
  | EVAL is_today = d == DATE_TRUNC(1 day, NOW())
  | STATS today = MAX(CASE(is_today, c, null)), base_max = MAX(CASE(is_today, null, c)),
          base_days = COUNT_DISTINCT(d)
  | WHERE today > base_max AND base_days >= 3
  ```

  `base_days >= 3` is load-bearing: both wlx and rtx data streams are on 7-day
  ILM, so the baseline is six days at best and shrinks as ILM deletes — during
  the investigation the oldest index moved forward a full day in three hours. A
  two-day baseline would fire on noise.
- **The four signals**: per-client churn (`0113`), band-steering burst (`0127`),
  CCE accept/reject ratio drift (`0126`/`0101` — this is what caught 6GHz
  disabling CCE, 37.68% -> 0.00%), and DHCP renew storm per MAC on hnd.
- **First step**: create ONE ES|QL rule through the Kibana alerting API by hand
  and confirm the `esqlQuery` params are accepted, before touching the
  generator. If they are rejected, the fallback is a small producer on CT111
  writing straight to `self-heal-state` — the issue path downstream is already
  proven and does not change either way.
- **Wait for**: about a week of the #948 rules running, so the false-positive
  rate of the threshold half is known before adding a noisier class on top.

Status 2026-09-20: the baseline-comparison half is still unwritten.
`esqlQuery` / `esql` matches only `TODO.md` on origin/main — no Kibana
alerting rule, no generator, and no CT111 producer references it. The
one-rule-by-hand first step has not been taken.

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

Status 2026-09-06: unchanged. `cookbooks/lxc-kibana/default.rb` still matches a
single spelling — `{ term: { "process.name": $process } }` at L101, with the KQL at
L76 interpolating one `${process}`. #833 and #852 only chased the spelling of the
day; the list-accepting fix this entry asks for is not in.

Status 2026-09-20: unchanged, and the location recorded on 09-06 is wrong. The
single-spelling match lives in
`cookbooks/lxc-kibana/files/setup-process-alerts.sh:101` (`{ term: {
"process.name": $process } }`), not in `cookbooks/lxc-kibana/default.rb:101` —
`process.name` has 0 hits in `default.rb`. Locate by file name; the 09-06 path
sends the probe to the wrong file.

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

Status 2026-09-06: no drift check yet. `rg 'serial'` across `cookbooks/**/*.rb`
returns no cert-related hit, and `git log --grep='cert serial' -i` on main is empty.

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

Status 2026-09-06: not applied. `~/.claude/docs/rust.md` (4935 B, mtime Aug 1)
matches neither `EPERM` nor `sandbox`; positive control `Rust|cargo` = 14 hits, so
the file is being read and the addendum is genuinely absent.

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

Status 2026-09-20: Alertmanager is still not deployed by any cookbook. `git
grep -ln alertmanager origin/main -- cookbooks/` returns one unrelated file
(`elastic-agent/files/elastic-agent.synthetics-input.yml`) — no receiver
definition, no unit, no cookbook. The invisibility gap is intact, which also
keeps the self-deadlock item below blocked by design.

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

Status 2026-09-20: not adopted. In home-monitor origin/main,
`elastic-billing-reader` still has a single static `aws_iam_access_key`
(`pve-monitoring-aws-billing.tf:35`), while the primary/secondary harness it
is meant to copy exists only at `pve-bootstrap-iam.tf:54` (`for_each =
toset(["primary", "secondary"])`). Both coupled gaps are open.

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

Status 2026-09-06: unchanged — a fresh headless session on sh1-cloud still lists the
full `gws-*` / `recipe-*` / `persona-*` set in its available-skills block.

Status 2026-09-20: unchanged — this weekly headless reconcile session's own
available-skills block still carries the full `gws-*` / `recipe-*` /
`persona-*` set, so the listing cost is paid by every scheduled run on this
host, not only by interactive sessions.

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

Status 2026-09-06: 8 files still match. `grep -rliE 'cognee|cognify|:8001|:8002'
~/.claude/projects/*/memory/` = 8 hits out of 77 memory files on sh1-cloud.

Status 2026-09-13: still 8 files. Same `grep -rliE 'cognee|cognify|:8001|:8002'
~/.claude/projects/*/memory/` = 8 hits, now out of **89** memory files (77 a week
ago) — the numerator is flat while the denominator grows, i.e. the stale set is
not self-correcting on its own and nothing new is picking up the old references.

Status 2026-09-20: still 8 files, now out of **91** memory files (89 a week
ago, 77 on 09-06). Same `grep -rliE 'cognee|cognify|:8001|:8002'
~/.claude/projects/*/memory/` on sh1-cloud. Third consecutive week of a flat
numerator against a growing denominator.

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

Status 2026-09-20: unchanged. `idleTimeout|idle_timeout|maxConcurrent` = 0
hits under `cookbooks/remind/` on origin/main (positive control:
`cookbooks/remind/default.rb` matches `remind`), so the daemon still has
neither a read/idle timeout nor a max-connection cap.

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

Status 2026-09-20: defect 1 is still present at
`cookbooks/elastic-agent/linux.rb:314` — the `execute "render
elastic-agent.yml"` command string still opens with `set -euo pipefail`, which
dash rejects. Locate by resource name; this line number drifts between
releases.

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

Status 2026-09-06: still present. `cookbooks/ssh-keys/default.rb:383` runs
`ssh-keyscan -t rsa,ecdsa,ed25519 -T 10 github.com 2>/dev/null > "$TMP"`, and no fix
commit exists on main (`--grep` for keyscan returns only #786, which filed this
entry, and #353). The end-to-end check still needs a home-LAN Linux host.

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

Status 2026-09-13: all nine sites still present and still unwrapped, but **every
line number in the table above has drifted** — locate by enclosing resource name,
not by line. Current (`git grep -n 'set -euo pipefail'` on this branch):
`lxc-elasticsearch/default.rb` 266 / 292; `lxc-kibana/default.rb` 343 / 359 /
375 / 396; `lxc-monitoring/default.rb` 580 / 614 / 632. Each is still the first
line of a bare `execute … command <<~SH.strip` (verified by reading the three
lines above each hit), so no site has been wrapped in `bash -c` yet.

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

Status 2026-09-06: the blast-radius count is still unrun, and the target is not in
this repo — sh1-cloud is built by the `gcp-*` cookbooks in the zp-SHIN overlay
(`projects/mercari-setup/cookbooks/gcp-{aws-federation,cli-tools,es-memory,
metadata-route-guard,ssh-keys,tailscale,ubuntu-slim}`), so the grep has to run there.

Status 2026-09-13: blast-radius count RUN in the overlay, and it is small. In
`kouzoh/zp-SHIN` `projects/mercari-setup/cookbooks/`, the literal
`owner node[:setup][:user]` matches **0** files (`git grep -lF`), and the broader
`^\s+(owner|group)\s` matches **6 lines in 1 cookbook** — `mercari-git/default.rb`
:27/28, :36/37, :43/44 (three resources, each with both attributes). The `gcp-*`
cookbooks carry none. Root condition re-confirmed on the host:
`grep -c '^sh1_mercari_com:' /etc/passwd` = 0 while `getent passwd sh1_mercari_com`
returns uid/gid 569775000, so mitamae's uid→name mapping genuinely has no local
source. With a 3-resource blast radius, option (a) (drop `owner`/`group` under
`node[:setup][:home]` + a lint check) is a small diff — the noise seen on every
apply comes mostly from the public `setup` cookbooks, which also run on this host,
so re-scope the count there before choosing.

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

Status 2026-09-06: unchanged. No commit since #916 touches the lease parser; #962
(today) rewrote parts of `vector.toml` for wlx313's syslog mapping only.

Status 2026-10-02: the verb list is wrong as well, so the first step above is not
enough on its own. The routers log `Allocates` and `Released`, not `Assigns` /
`Releases`: over 2026-09-25 → 10-02, hnd had 3,776 `[DHCPD]` documents (207
Allocates, 3,568 Extends, 1 Released) with 0 parsed, and itm had 304 (97
Allocates, 207 Extends) with exactly the 207 Extends parsed. New leases — the
event that shows a rotated Private Wi-Fi Address — are therefore unparsed on
both routers. Use `(?P<dhcp_event>Allocates|Extends|Released|Assigns|Releases)`
together with the optional interface token. Found while tracing ann's Mac's MAC
rotation (cookbooks/mac-block-tracker).

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

Status 2026-09-20: the repo side is unchanged —
`cookbooks/pve-host/default.rb` mentions `accept_ra` only in comments (:101,
:118, :120) and sets no `token` / `accept_ra` on vmbr1. The deciding probes
(`ss -6 -tunap`, `ip -6 route get <CT ULA>`) need the PVE host itself, which
does not resolve from sh1-cloud, so this item cannot close from the weekly
headless run — it needs a session with fleet reach.

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

Status 2026-09-06: the lint check is still absent. `bin/lint-cookbooks` (43 KB)
matches none of `import_|imported|deploy map|deploy_map`.

## wlx313 syslog depends on a DHCP lease that nothing reserves (Medium)

wlx313 (ITM) started shipping syslog on 2026-09-06 (#949): `syslog host
192.168.1.76` was set on the AP, and `192.168.1.155` — the address a 300s
tcpdump on the PVE bridge showed it actually sending from — was added to the
Vector source map in `cookbooks/lxc-monitoring/files/vector.toml`. That entry
is keyed on an address the AP does not own.

- **Why it matters**: the AP runs `ip route default gateway dhcp` with no
  static address, and the ITM RTX830 hands out `192.168.1.150-192.168.1.225`
  (`dhcp scope 1`, expire 12:00) with **no `dhcp scope bind`** for
  `ac:44:f2:5a:d7:20`. If the AP ever takes a different lease, every packet
  falls through to the map's `abort` and wlx313 goes silently back to zero
  events — exactly the failure that hid the wlx323 fault for weeks while `.41`
  was declared and the AP was sending from `.27`. The `syslog_silent_wlx313`
  rule does fire on it, so it is detected, but the address is a fresh guess
  each time.
- **First step**: add a `dhcp scope bind` for `ac:44:f2:5a:d7:20 -> .155` to
  `config/rtx-routers/itm/config.txt.tftpl` in home-monitor, the way
  `rtx-hnd.tf` binds the HND devices. Verify with `show status dhcp` on the ITM
  RTX830 that the bind is in the running config, since the ITM router is
  configured by SFTP push to `/system/config0` and the template has drifted
  from the device before (home-monitor #139).
- **Alternative**: give the AP a static address outside `.150-.225`, mirroring
  how wlx402 sits at `.5` and wlx323 was moved to `.6` for this same reason
  (setup #887 / home-monitor #123). That also needs the Vector map updated in
  the same change.
- **Why not done here**: both touch home-monitor terraform / a network device's
  running config, which is outside the self-heal loop's autonomous envelope
  (network gear is read-only to it, and home-monitor TF is needs-human).

Status 2026-09-20: still unreserved. In home-monitor origin/main,
`config/rtx-routers/itm/config.txt.tftpl` carries **no** `dhcp scope bind`
(positive control: `dhcp scope` = 1 hit), and the AP's MAC `ac:44:f2:5a:d7:20`
appears nowhere in the repo at all. The Vector source map therefore still keys
on an address the AP does not own.

## No AP-liveness signal exists; "is wlx402 alive" is inferred from log volume (Medium)

- **Failure class**: `Net: syslog silent (<ap>)` is a document-count absence
  rule, so on an AP whose log stream is entirely client-driven it cannot
  separate "the AP is dead" from "nobody is using the WiFi". wlx402 has no
  client-independent floor except one scheduled burst per day, so the window
  has to exceed 24 h to stop flapping (setup#965 30 -> 360 min, setup#975
  360 -> 1560 min). Each widening buys quiet at the cost of detection latency,
  and 26 h is where that curve ends — the rule is now a pipeline-liveness
  check, and a genuinely dead wlx402 stays undetected for about a day.
- **When it triggers**: any AP loses power, wedges, or drops off the bridge.
  Nothing pages until its once-daily scheduled message fails to arrive.
  wlx313 (ITM) is in the same shape with a 30 min window it has not yet
  earned, because there is still too little history to measure its gaps.
- **First step**: pick the delivery path, because both candidates are outside
  the self-heal loop's autonomous envelope and neither is obviously better:
  (a) blackbox_exporter already ships a `tcp_connect` module
  (`cookbooks/lxc-monitoring/files/blackbox.yml`) and the alert-rule pattern
  exists (`files/alerts/rtx-snmp.yml`), so a `wlx-liveness` job probing
  `.5:80`, `.6:80`, `.155:80` plus a `probe_success == 0 for: 5m` rule is a
  small diff — but the Prometheus alert family is shipped DISABLED
  (`SELF_HEAL_PROM_URL=""` in `cookbooks/self-heal-observer/default.rb`), so
  it reaches nobody until that is switched on, which turns every `critical`
  Prometheus alert into a GitHub issue at once; or (b) a Kibana synthetics TCP
  monitor, which already has a working delivery path (the `Uptime monitor
  down` family) but lives in home-monitor terraform = needs-human.
- **Then**: once a liveness signal exists, drop the syslog-silence windows back
  to something short, since their job reverts to catching a Vector/ingest drop
  rather than a dead AP.

## wlx402's clock has been wrong since its 2026-08-29 reboot (Low)

- **Failure class**: `show environment` on wlx402 (192.168.1.5) reports boot
  time `2020/01/01 09:00:17` and current time in 2020, i.e. the AP has been
  free-running from its power-on default for its whole uptime. It runs
  `schedule at 1 startup * ntpdate ntp.nict.jp syslog` and
  `schedule at 2 */* 00:00 * ntpdate ntp.nict.jp syslog`, so ntpdate has
  failed every attempt since the reboot. wlx323 (192.168.1.6) booted in the
  same power event (`2026/08/29 17:39:36`, elapsed within an hour of wlx402's)
  and holds a correct clock, so this is specific to wlx402, not to the site.
- **Why it matters**: `show log` is the only source for the window ES has
  already aged out, and its timestamps are unusable without first deriving the
  offset from `show environment` — 2432 days in the setup#975 investigation.
  Anyone reading that log during an incident will mis-order events.
- **First step**: on wlx402, check whether `ntp.nict.jp` resolves and whether
  the reply is reachable — the AP is configured with `dns server 192.168.1.253`
  and the name currently returns AAAA records, so an AP without usable IPv6
  egress would fail there. Compare against wlx323's `show config` NTP/DNS
  lines, which work. Fixing it is a device config change = needs-human; the
  self-heal loop is read-only on network gear.

## Project-scoped always-loaded rules have never been audited (Medium)

- **Failure class**: the 2026-09-16 `claude-md-audit` measured and audited the
  1,241-line global always-loaded set (`~/.claude/CLAUDE.md` + `rules/` + the
  `@`-imported `docs/knowledge-persistence.md`) and never looked at the
  project-scoped set this repo adds on top: `CLAUDE.md` 169 lines +
  `.claude/rules/{ruby,shell,infrastructure}.md` 530 lines = 699 lines
  (measured 2026-09-17). None of it has been checked for staleness, for rules
  the model now does natively, or for detail that belongs in on-demand `docs/`.
- **Why it matters**: a session opened in this repo carries 1,940 always-loaded
  lines, and the audit's headline conclusion — that only three levers actually
  reduce the cost — was derived from the global half alone. The audit's own
  Critic named this as its largest gap.
- **First step**: run the same three sieves over `.claude/rules/infrastructure.md`
  (the largest of the three) — per section, is it (a) stale against the current
  fleet, (b) native model behaviour now, or (c) detail whose body can move to
  `~/.claude/docs/infrastructure-detail.md`, which already exists and already
  receives pointers from that file.

## The 90 file memories have never been cross-checked against the rules files (Low)

- **Failure class**: `~/.claude/projects/*/memory/` holds 90 markdown memories
  totalling 2,463 lines (measured 2026-09-17). They are auto-mirrored to the
  memory MCP, surface through `recall` at session start, and overlap the
  always-loaded rules by an unmeasured amount. No inventory exists, so a rule
  and a memory can assert the same thing — or contradict each other — with no
  mechanism that would notice.
- **Why it matters**: duplication splits the correction path.
  `docs/knowledge-persistence.md` already records the measured case where a
  hand-written duplicate outranked the corrected canonical mirror in `recall`.
  A rules-versus-memory contradiction has the same shape, and nothing is
  looking for it.
- **First step**: list the title and first line of all 90, group each by the
  rules file it most overlaps, and report two sets — memories that restate
  always-loaded text (deletion candidates) and memories that contradict it
  (correction candidates). Read-only for the first pass; no edits.

## self-heal-resolve prose still describes the is_bot condition #963 removed (Medium)

- **Failure class**: #963 (`d80c330`) changed exactly one line of
  `cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md` — the jq
  `is_bot` definition — dropping the unanchored
  `test("self-heal-(resolve|create)")`. The surrounding prose was not updated:
  the numbered list still names that substring match as condition 2 of three,
  the two lines under it still explain a migration safeguard (#587/#588's
  unmarked `🔧 着手` / `🔬 診断` comments) the code no longer provides, and the
  inline comment above the jq still reads
  `marker OR resolve/create を含む OR 旧 create プレフィックス` while the code
  implements two conditions.
- **Why it matters**: this file IS the loop's instructions, so the divergence is
  between what the loop is told and what it does. A reader following the prose
  expects an unmarked legacy bot comment to be filtered out; the code now reads
  it as an operator signal. #963's commit message states that fail-open
  direction was deliberate and costs one redundant cycle — but nothing in the
  file says so, so the next editor is as likely to "restore" the removed
  pattern and rebuild the permanent lock #963 removed.
- **First step**: cut the numbered list to two conditions, delete the
  migration-safeguard explanation, fix the inline comment, and carry #963's
  fail-open rationale into the file as one sentence naming what it trades.
  `skills/linear-resolve/linear_queue.py`'s module docstring already states the
  lesson in the right shape — reuse its framing.

## linear-resolve is deployed with no runner, timer, or dedicated IAM (Medium)

- **Failure class**: `skills/linear-resolve/` reached this host in the
  2026-09-17 apply (3 files, verified executable). Its own closing line says the
  runner, the systemd timer and the read-only `linear-probe` IAM profile are a
  separate PR, so the loop runs only on manual invocation — and a manual run
  stops at step 2: the GraphQL poll to `api.linear.app` returns `HTTP 401`
  because `LINEAR_API_KEY` is not in the environment and nothing on this host
  supplies it. A repo-wide grep finds the variable named only in the skill's own
  SKILL.md.
- **Why it matters**: the skill exists to cut the measured escalation latency
  (261 h and 305 h on the GitHub loop) down to one poll interval, which requires
  running unattended. The deterministic half is already verified working — the
  selector picks the least-recently-updated actionable issue and correctly
  classifies the #963 GO-comment case, checked against a 4-case fixture on
  2026-09-17 — so only the plumbing is missing.
- **First step**: decide where the API key lives; the SSM-gated pattern
  `probe.sh` already uses for its own credentials is the existing facility, so
  probe that before designing anything new. Then the runner script and a
  `systemd` user timer at the 10-minute default, verified by next-elapse rather
  than `is-active` per the timer gate in `.claude/rules/infrastructure.md`.


## cookbooks/rust does not install rust-analyzer, which rustup is now the only source of (Medium)

- **Failure class**: `rust-analyzer` reached this host through a mise shim,
  because `~/.config/mise/config.toml` declared `rust = "latest"`. That entry is
  gone as of 2026-09-19 (reason below), so rustup is the only supplier — and
  `cookbooks/rust` installs rustup with the default profile, which does not
  include the `rust-analyzer` component. A rebuilt host therefore gets a
  `rust-analyzer` that resolves to rustup's shim, answers "unavailable for the
  active toolchain", and has no later PATH entry to fall through to.
- **Why the mise entry went away**: while it was there, mise ran
  `rustup component list --installed --toolchain 1.96.0` on every shim
  activation — measured at ~1 rustup per shim call. The coralline statusline
  refreshes once a second and calls `jq`, which on this host resolves only to a
  mise shim (`/usr/bin/jq` does not exist), so every live Claude Code session
  produced about one rustup per second. rustup unlinks
  `$CARGO_HOME/bin/rustup-init` on every invocation (`cleanup_self_updater`,
  `self_update.rs` 1416-1425) and `prepare_update` downloads the new rustup into
  that exact path, so the self-update's target was deleted mid-transfer every
  time and `rustup update stable` aborted the whole apply with a misleading
  `failed to set permissions ... (os error 2)`. Removing `rust` from the mise
  config took the measured churn from 29 rustup processes per 4 s to 0 per 12 s;
  `rustup self update` then completed (1.29.0 → 1.29.1) and
  `rustup update stable` exits 0 with auto-self-update back on.
- **What is host-local on pro-dev**: `rustup component add rust-analyzer` for
  both the default (stable) and the 1.96.0 toolchain. No cookbook adds it.
  `~/.config/mise/config.toml` is not cookbook-managed either — no
  `mise_tool "rust"` exists anywhere under `cookbooks/` — so that tool list is
  hand-maintained per host and `rust = "latest"` can reappear on another one.
- **First step**: add `rustup component add rust-analyzer` to
  `cookbooks/rust/default.rb`, guarded by a `not_if` on
  `rustup component list --installed | grep -q rust-analyzer`, so the LSP
  survives a rebuild. Separately decide whether the hand-maintained mise tool
  list belongs under cookbook management at all — the failure it caused here is
  fixed, but nothing stops it recurring on a host where someone runs
  `mise use -g rust`. Delete this entry in the resolving commit.

Origin: 2026-09-19 pro-dev. Supersedes the entry filed earlier the same day in
#1002, which recorded `rustup set auto-self-update disable` as the fix. That
workaround has since been reverted: the driver is gone, so it was no longer
load-bearing and would have read as a setting with no surviving reason.

## pro-dev's /home/shin1ohno/.claude never converges under auto-mitamae (Medium)

- **Failure class**: auto-mitamae applies pro-dev as root (`hosts.json` user
  root, canary), so `cookbooks/claude-code` writes `node[:setup][:home]` =
  `/root/.claude`. The operator's `/home/shin1ohno/.claude` only moves on a
  manual `./bin/mitamae local` run as shin1ohno. Observed 2026-09-27: the
  deployed `CLAUDE.md` was the 2026-09-08 version and `hooks/mirror-file-memory.rb`
  the 2026-08-21 one, weeks behind main.
- **Why it matters**: every hook and rule fix merged to main (e.g. #1043's
  UTF-8 shim) silently does not reach the host where most sessions run.
  `cookbooks/memory-mirror` already resolves the real user under root; the
  claude-code cookbook does not.
- **First step**: apply the same target-user resolution to `cookbooks/claude-code`
  when running as root on pro-dev (see `cookbooks/memory-mirror/default.rb`),
  dry-run it as root, and confirm owner/mode of the rendered files.

## memory-mirror follow-ups after the first rollout (Medium)

- **Failure class**: the machine client `memory-mirror` (CLIENT_POLICY:
  ingest,forget@file-memory) shipped with accepted gaps.
  - ingest supersedes any `file-memory` doc with the same doc_key, whoever wrote
    it — needed once so the first sweep can take over the 105 docs migrated by
    hand on 2026-09-26, but a leaked credential can overwrite other hosts' docs.
  - `PROXY_SHARED_SECRET` is unset on CT119, so a local process there can forge
    `X-Verified-*` and bypass the policy. Once set, read tools also need it
    (the gate now parses identity on every tools/call).
  - CT119 has no persistent journald, so `POLICY` / `AUDIT deny` lines are lost
    on restart.
  - memory-work (sh1-cloud) runs the same server code from the private overlay.
    `server.py` falls back to an ungated FastMCP when `policy_mcp.py` is absent
    and CLIENT_POLICY is unset, but whether the overlay deploys by MANIFEST and
    whether it should adopt a CLIENT_POLICY of its own is unverified (air and
    the overlay were unreachable from pro-dev).
  - neo is offline (118 days); it needs the interactive darwin apply, `--check`
    and a first manual `--sweep` when it returns.
- **First step**: after the first sweep on every personal host, add a
  `provenance.agent` condition to `_supersede_prior_doc` for client_credentials
  callers (or split into per-host clients bound to a doc_key prefix), then set
  `PROXY_SHARED_SECRET` in both units.

## mcp-probe's memory e2e has been red since 2026-08-29 and sends its secret over LAN HTTP (Medium)

- **Failure class**: `cookbooks/mcp-probe/files/probe.py` probes
  `/memory/mcp/` with a trailing slash, which returns 307 after auth, so the
  memory e2e metric has read 0 since 2026-08-29. `fetch-secrets.sh` also points
  `HYDRA_TOKEN_URL` at `http://192.168.1.71:4444`, so the client secret crosses
  the LAN in plaintext. Separately, the live Hydra registration of
  `monitoring-prober` still lists the retired `cognee` audience while
  `bin/register-mcp-prober` does not.
- **First step**: drop the trailing slash, switch the token URL to
  `https://mcp.ohno.be/oauth2/token`, and re-register the prober's audience;
  verify the textfile metric turns 1.

## claude-code's settings.json merge drops live-only `env` and `hooks` entries on every apply (Low)

- **Failure class**: `cookbooks/claude-code` writes `existing.merge(managed)`,
  a shallow merge, so the managed `env` and `hooks` maps replace the live ones
  wholesale. An env var or hook added to the live `~/.claude/settings.json`
  (Claude Code's own settings UI, the update-config skill) is removed by the
  next apply — unattended on pro-dev. `permissions` and `enabledPlugins`
  already get an explicit per-field merge for exactly this reason.
- **Why it matters**: the removal is silent. `sensitive true` (check 15) now
  keeps the removed values out of the runner log, but the loss itself remains.
  Switching `env` to a per-field merge also changes semantics: an entry
  deleted from `files/settings.json` would then stay in the live file.
- **First step**: decide per field (env, hooks) between "managed set wins
  wholesale" and "live-only entries survive"; for the latter, add
  `merged["env"] = existing.fetch("env", {}).merge(managed["env"])` next to the
  enabledPlugins merge and dry-run it against a live file carrying an extra key.

## LXC journald never reaches Elasticsearch (Medium)

- **Failure class**: `logs-system.journal` holds only host `pro` (the PVE host,
  468,527 docs as of 2026-09-27); none of the 17 LXCs ship journald, and the
  `system.syslog` / `system.auth` data streams do not exist. Only elastic-agent's
  own logs arrive from the LXCs. Found while checking whether mitamae diffs had
  leaked secrets into ES (they had not).
- **Why it matters**: service failures inside an LXC (unit crashes, auth
  rejections, OOM) are invisible to Kibana and to the self-heal observer unless
  a metric happens to cover them.
- **First step**: on one LXC, compare `elastic-agent inspect` output against
  `cookbooks/elastic-agent/files/elastic-agent.linux.yml.tmpl`'s journald input
  and check whether the unprivileged container can read `/var/log/journal`
  (persistent storage may be off: CT119 has no journal files).

## auto-mitamae orchestrator log grows without rotation (Low)

- **Failure class**: CT111 `/var/log/auto-mitamae-orchestrator.log` is appended
  by three cron jobs with no logrotate rule (4.5 MB / 53,922 lines on
  2026-09-27, mode 0644). It carries status lines only, no mitamae output.
- **First step**: add a logrotate drop-in in `cookbooks/auto-mitamae-orchestrator`
  (weekly, rotate 4, compress, copytruncate) and verify with
  `logrotate -d /etc/logrotate.d/auto-mitamae-orchestrator`.
