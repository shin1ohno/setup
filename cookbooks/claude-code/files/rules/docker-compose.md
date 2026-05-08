---
globs: ["docker-compose*.yml", "docker-compose*.yaml", "compose.yml", "compose.yaml", "**/files/docker-compose*.yml"]
---

# Docker Compose Operational Rules

## Docker Compose Branch-Dep Pre-Deploy Check

Before running `docker compose up -d --build` (with or without a service argument) from a feature branch, verify the branch's base is up-to-date with every sibling feature already merged to `origin/main`.

```
git fetch origin
git log origin/main..HEAD --oneline
```

If the working tree's branch was cut from `origin/main` *before* a sibling feature PR merged, the working tree contains pre-merge code for any shared service. `docker compose up -d --build <service>` rebuilds the named service from that pre-merge code, **and** rebuilds any sibling service whose Dockerfile context has changed relative to the branch's base — which silently regresses the sibling feature's deployed state.

**Safe pattern** when stacking work:

1. `git fetch origin && git merge origin/main` — pull merged sibling features into the working branch first
2. `cargo build` / `npm run build` to confirm the merge compiles cleanly
3. `docker compose up -d --build <service>` for the deploy

**Anti-pattern**: running `docker compose up -d --build weave-web` from a feature branch that diverged from `origin/main` two PRs ago. The compose run will rebuild `weave-server` too if its working tree has any change relative to the branch base — and the rebuild produces a **regressed** weave-server image because the branch lacks the parent PRs' server-side commits.

This rule exists because the 2026-04-27 cross-edge intent forwarding session deployed weave-web from a feature branch cut from `origin/main` while PR #51 (cross-edge server logic) was still open. The compose rebuild produced a weave-server image without PR #51's `find_edge_for_service` and `EdgeToServer::DispatchIntent` arm, immediately regressing Hue / Roon dispatch. Recovery required merging PR #51, merging `origin/main` into the working branch, and rebuilding weave-server again — costing two extra deploy cycles.

## Container state path audit when `user:` is non-root

When designing or reviewing a `docker-compose` service that:

1. Runs as a non-root UID (`user: "1000:1000"`, `user: "${UID}:${GID}"`, or any explicit non-zero UID)
2. AND persists state via a path derived from `$HOME` or any `XDG_*` environment variable (Rust `dirs_next::config_dir()`, Python `appdirs`, Go `os.UserConfigDir`, Node `os.homedir()`, etc.)
3. AND has a bind-mount intended to receive that state on the host

…audit explicitly what `$HOME` resolves to **inside the container** before the mount is wired. Three traps in sequence:

**Trap 1 — `HOME=/`**: Many minimal base images (`alpine`, `debian:bookworm-slim`, distroless variants) do not set `HOME` for non-root UIDs that lack a `useradd` entry. The process inherits `HOME=/` from the docker init env. `dirs_next::config_dir()` returns `/.config`, which a non-root UID cannot create or write under.

**Trap 2 — mount destination unreachable from the resolved path**: Even when the host bind-mount lands at `/root/.config/roon-rs` (the cookbook's `home` interpolation), the application uses `/.config/...` not `/root/.config/...` — so the mount catches zero writes. The state is silently written to the container's writable layer (or fails) and lost on restart.

**Trap 3 — `/root` mode 700**: If `HOME=/root` is set but the running UID is not 0, the default image `/root` mode 700 root:root blocks traversal. `Permission denied` even when the deeper directory is correctly chowned.

**Audit checklist** before merging the cookbook / compose change:

1. `docker exec <c> sh -c 'id; env | grep -E HOME=|XDG_'` — confirm running UID and what `HOME` / `XDG_*` resolve to
2. `docker exec <c> sh -c 'ls -ld / /root /home 2>&1'` — confirm traversability for the running UID
3. Choose ONE of:
   - Set `XDG_CONFIG_HOME` (or the language-specific equivalent) explicitly in the `environment:` block to a path **inside the bind-mount**, e.g. `XDG_CONFIG_HOME: /data` + mount `/var/lib/<service>:/data:rw`
   - OR set `HOME` explicitly to a path you know is mounted and traversable for the running UID
   - OR add a Dockerfile `USER <name>` directive that creates a real home directory at image build time
4. Verify with `docker exec <c> sh -c 'echo probe > $XDG_CONFIG_HOME/probe && rm $XDG_CONFIG_HOME/probe'` after deploy

Prefer option (a) `XDG_CONFIG_HOME` override + system-standard `/var/lib/<service>/`: it's traversable by any UID by default (mode 755 root:root inherited from `/var`), system-conventional, and decouples the host path from any home-directory ambiguity. Avoid `/root/...` for non-root containers entirely.

**Codify in the cookbook**:

```ruby
# State directory tree owned by container UID (matches compose `user:` directive).
# /var/lib/<service>/ is system-standard and traversable; /root/... is unsafe
# for non-root containers because the default image /root mode is 700 root:root.
state_dir = "/var/lib/<service>/state"

directory state_dir do
  owner "1000"   # MUST be String per ~/.claude/rules/ruby.md
  group "1000"
  mode "755"
end
```

```yaml
# compose
environment:
  XDG_CONFIG_HOME: "/data"
volumes:
  - /var/lib/<service>/state:/data:rw
```

This rule exists because lxc-roon-mcp cookbook (PR #131, 2026-05-05) initially mounted `${home}/.config/roon-rs:/root/.config/roon-rs:rw` while the container ran as UID 1000 with `HOME=/`. The application wrote to `/.config/roon-rs/` (unwritable for UID 1000), the bind-mount caught zero writes, and `roon_api::registry: Failed to persist token: Permission denied (os error 13)` warns repeated on every Roon Core handshake. Fixed by switching to `/var/lib/roon-mcp/state` host path + `XDG_CONFIG_HOME=/data` env. The audit checklist would have caught this at plan time.

## docker-compose Notify-Driven Restart Requires `--force-recreate`

Cookbook `execute` resources that restart a docker-compose stack via `notifies :run` (action `:nothing`, fired when a `remote_file` content changes) MUST run `docker compose up -d --force-recreate`. Plain `up -d` is a **no-op** when the image digest and compose spec are unchanged — it does not detect bind-mount file content changes, so the cookbook's "config edited" notify silently leaves the running container serving the old config until a manual `docker restart`.

```ruby
# WRONG — config edits silently ignored on already-running containers
execute "restart <service>" do
  command "docker compose -f #{compose_path} up -d"
  user user
  action :nothing
end

# RIGHT — recreates the container so bind-mounted config edits take effect
execute "restart <service>" do
  command "docker compose -f #{compose_path} up -d --force-recreate"
  user user
  action :nothing
end
```

**`ensure X running`** (initial-state) executes are intentionally NOT touched. Their `only_if` shell guards already short-circuit when the desired services are running, so re-creating them every mitamae run would regress idempotency. The notify-driven path is the correct boundary for `--force-recreate`: it fires exactly when a cookbook-managed config file changed.

**Detection signal**: `mitamae apply` reports success after a `remote_file` config change, but `docker exec <container> cat /etc/<service>/config.yml` (or equivalent) still shows the old content. Or: the running daemon's `/api/v1/status/config` endpoint reports stale settings. Or: `docker ps --format '{{.Names}}: {{.RunningFor}}'` shows uptime older than the latest config edit.

**Detection grep** when reviewing a docker-compose-deploying cookbook:

```
git grep -B3 'action :nothing' cookbooks/ | grep -A2 'execute "(docker compose )?restart' | grep 'docker compose .* up -d' | grep -v 'force-recreate'
```

Any hit is a candidate.

This rule exists because the 2026-05-06 Phase 2b verify session shipped PR #154 (`prometheus.yml: honor_labels: true`), and the cookbook's `restart monitoring` notify fired correctly — but the bare `up -d` was a no-op, so the running prometheus container kept the pre-edit config until manual `docker kill --signal=SIGHUP`. Recovery swept 7 cookbooks (PRs #158 + #159) to add `--force-recreate` to the notify-driven paths: ai-memory, cognee, hydra, lxc-consent, lxc-monitoring, lxc-roon-mcp, lxc-weave.

## Grafana Datasource Provisioning — Pin `uid` Explicitly

Every Grafana datasource declared via provisioning YAML (`/etc/grafana/provisioning/datasources/*.yml`) MUST include an explicit `uid:` field. Without it, Grafana auto-generates a random uid (e.g. `PBFA97CFB590B2093`) at first container boot. Dashboard JSON checked into the cookbook references the datasource via `"uid": "<slug>"` — if those refs don't match the auto-generated uid, every panel renders **"No data"** despite the underlying Prometheus query returning valid results.

```yaml
# WRONG — Grafana auto-generates a random uid; dashboard JSON refs fail
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true

# RIGHT — pin a stable lowercase slug matching the dashboard JSON
datasources:
  - name: Prometheus
    uid: prometheus       # ← matches "uid": "prometheus" in dashboards/*.json
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
```

**The diagnostic path is expensive** because the visible symptoms point AWAY from the actual cause:

- Prometheus `/api/v1/query` returns valid metrics ✓
- Prometheus targets are UP ✓
- Grafana healthcheck returns OK ✓
- Dashboard JSON loads correctly (no parse error) ✓
- Every panel shows "No data" ✗

The only way to diagnose without this rule is to manually inspect `GET /api/datasources` for the actual uid, compare against the dashboard JSON's `"uid"` ref, and notice the mismatch. Worth ~15 minutes per incident.

**Detection signal**: a dashboard with valid PromQL queries showing "No data" across all panels. Compare `curl -u admin:<pw> http://<grafana>/api/datasources | jq '.[].uid'` against `grep -hoE '"uid":[^,]+' /path/to/dashboards/*.json | sort -u`.

After fixing the provisioning yaml, **`docker compose restart grafana`** is required (or full container recreate) — Grafana reloads provisioned datasources on container start, not on file watch.

This rule exists because the 2026-05-06 Phase 2b verify session shipped a Grafana auto-mitamae-fleet dashboard with `"uid": "prometheus"` refs but the provisioning yaml omitted the explicit `uid:` field. Every panel showed "No data" until PR #156 pinned `uid: prometheus` in the provisioning yaml and a `docker restart monitoring-grafana` reloaded the datasource.

## UDP Listener Containers Require `network_mode: host`

Docker's userland proxy (`docker-proxy`) does not reliably forward UDP packets — packets arrive at the host's published port, the container's UDP listener binds inside the container netns, but no packets surface inside the container. No errors logged. Symptom for syslog/SNMP-trap/StatsD/DNS receivers: the listener starts, the port appears bound (`ss -uln` shows `*:port` owned by docker-proxy), `/proc/net/udp{,6}` inside the container shows the listener — but Promtail-style `entries_total` counters stay at 0 even when packets flood in from the LAN.

Empirically observed on PVE unprivileged LXC + bridge + nesting=true (2026-05-07 setup PR #199), but the issue isn't unique to that combination — `docker-proxy` UDP forwarding is broken across many docker installations. Don't wait to find out if your specific stack is affected.

**Rule**: any container that receives UDP traffic — syslog collectors (Promtail, Fluentd, Logstash), SNMP trap receivers, StatsD, DNS servers — MUST use `network_mode: host`. TCP-only containers don't need this.

```yaml
promtail:
  image: grafana/promtail:3.6.10
  network_mode: host       # required: docker-proxy does not reliably forward UDP
  command: -config.file=/etc/promtail/promtail-config.yaml
  # NO `ports:` block — incompatible with host net, would log a warning
  volumes:
    - ./promtail-config.yaml:/etc/promtail/promtail-config.yaml:ro
```

Side effects of `network_mode: host`:
- `ports:` block is ignored (remove it to avoid "ports not exposed" warnings)
- docker-compose service-name resolution (`http://loki:3100/...`) is unavailable — switch to `127.0.0.1:<port>` if the peer service binds 127.0.0.1, OR move both services to host net
- Prometheus scrape targeting changes — `localhost:<port>` from the host now works; the bridge IP doesn't apply

This rule exists because setup PR #199 was 100% a `network_mode: host` migration after PR #198 deployed Promtail with default bridge networking and zero UDP packets reached the syslog target despite the listener binding correctly. The OS-level UDP path was verified working with a Python listener on the same port — confirming it was a docker-proxy issue, not network.

## Loki / Promtail Minimum Version: 3.x for Syslog UDP

Promtail 2.9.x has an undocumented defect where the syslog UDP target silently discards all received messages. The listener starts, `promtail_syslog_target_entries_total` is exposed as a metric but never increments. `parsing_errors_total` and `empty_messages_total` also stay 0 — packets reach the OS socket but never surface to Promtail's read loop. Verified via Python UDP listener on the same port: OS layer fine, Promtail-internal issue.

The 2.9.x series is Grafana's most-cited version in tutorials and Loki "stable" track. Defaulting to it produces a non-functional syslog receiver.

**Rule**: when adding Loki + Promtail to a monitoring stack for UDP syslog ingestion, pin to **Promtail 3.6+ and Loki 3.6+** (matching versions, verified working as of 2026-05-07). Never use 2.9.x even if upstream marks it stable.

```yaml
services:
  loki:
    image: grafana/loki:3.6.10        # NOT 2.9.x — see syslog UDP comment
    ...
  promtail:
    image: grafana/promtail:3.6.10    # NOT 2.9.x — UDP syslog target silently drops
    network_mode: host                 # see "UDP Listener Containers" rule above
    ...
```

Note: Grafana renamed Promtail to **Alloy** in the 3.x track; 3.6.x is the last `grafana/promtail` line maintained as a separate image. New deployments may eventually want to migrate to Alloy, but for existing Promtail-based pipelines 3.6.x continues to receive maintenance fixes.

This rule exists because setup PRs #198 → #199 → #200 chain: PR #198 deployed 2.9.10 with bridge networking (broke for both reasons), PR #199 fixed networking (still no entries — same metrics 0), PR #200 bumped to 3.6.10 and the next test packet immediately incremented `syslog_target_entries_total`. The UDP issue is a Promtail 2.9 regression, not a config bug.
