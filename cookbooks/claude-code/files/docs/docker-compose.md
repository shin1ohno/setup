# Docker Compose Operational Rules

Load when writing or deploying a docker-compose stack (compose YAML, a compose-deploying cookbook, `docker compose up/build` operations). Demoted from always-loaded `rules/` 2026-07 (claude-md-audit; the frontmatter `globs` gating never worked). Long examples + origin notes are in `~/.claude/docs/docker-compose-detail.md`.

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

Origin: 2026-04-27 — deployed weave-web from a branch missing an open server-logic PR, regressing dispatch.

## Container state path audit when `user:` is non-root

Detail: see `~/.claude/docs/docker-compose-detail.md#container-state-path-audit`.

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

Origin: 2026-05-06 — `prometheus.yml: honor_labels: true` notify fired but bare `up -d` was a no-op; running prometheus kept pre-edit config. Swept 7 cookbooks to add `--force-recreate`: ai-memory, cognee, hydra, lxc-consent, lxc-monitoring, lxc-roon-mcp, lxc-weave.

## Grafana Datasource Provisioning — Pin `uid` Explicitly

Detail: see `~/.claude/docs/docker-compose-detail.md#grafana-datasource-uid`.

## UDP Listener Containers Require `network_mode: host`

Docker's userland proxy (`docker-proxy`) does not reliably forward UDP packets — packets arrive at the host's published port, the container's UDP listener binds inside the container netns, but no packets surface inside the container. No errors logged. Symptom for syslog/SNMP-trap/StatsD/DNS receivers: the listener starts, the port appears bound (`ss -uln` shows `*:port` owned by docker-proxy), `/proc/net/udp{,6}` inside the container shows the listener — but Promtail-style `entries_total` counters stay at 0 even when packets flood in from the LAN.

Empirically observed on PVE unprivileged LXC + bridge + nesting=true (2026-05-07), but the issue isn't unique to that combination — `docker-proxy` UDP forwarding is broken across many docker installations. Don't wait to find out if your specific stack is affected.

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

Origin: 2026-05-07 — Promtail on default bridge networking got zero UDP packets despite the listener binding; a Python listener on the same port proved the OS path worked, isolating it to docker-proxy. Fixed by `network_mode: host`.

## Loki / Promtail Minimum Version: 3.x for Syslog UDP

Detail: see `~/.claude/docs/docker-compose-detail.md#loki-promtail-3x`.

## `docker import` hang post image-creation + `removal in progress` recovery

Detail: see `~/.claude/docs/docker-compose-detail.md#docker-import-hang-recovery`.

## PyTorch 2.7+ — CUDA libs required even for CPU-only inference

Detail: see `~/.claude/docs/docker-compose-detail.md#pytorch-cuda-cpu-only`.

## `docker compose up -d` Exit-1 with `No such container: <id>` — inspect `ps -a` before retrying

When `docker compose up -d` (with or without `--force-recreate` / `--build`) exits non-zero with `Error response from daemon: No such container: <hex-id>`, do NOT retry the `up` command and do NOT treat it as a deploy failure. This error originates from compose's post-create cleanup pass attempting to remove the previous container by ID — but dockerd has already purged that container as part of the recreate, so the cleanup hits a stale reference. The new containers were created BEFORE the cleanup error fired.

Probe `docker compose ps -a` first:

```
cd <compose-dir> && docker compose ps -a
```

- All desired services show `Up` or `healthy` → deploy succeeded; the exit-1 is cosmetic. Move on to verification.
- Any service shows `Exit <n>` or is absent → genuine failure; investigate `docker logs <name>` and only then consider retry.

The misclassification cost is real: a reflex "retry on exit-1" can recreate already-running containers (interrupting in-flight requests) or, worse, trigger a `down → up` cycle when the actual deploy is fine.

Origin: 2026-05-10 cognee leak fix — apply ended with `Error response from daemon: No such container: d8c8f128f3ae...` exit 1, but `docker compose ps -a` showed all 9 containers freshly recreated and serving. The error was compose cleaning a stale ID from the prior `down`.

## Throwaway-Preflight Pattern for Major Version Upgrades (native extensions + DB migrations)

Detail: see `~/.claude/docs/docker-compose-detail.md#throwaway-preflight`.

## Verify Actual Installed Library Version Before Debugging

Detail: see `~/.claude/docs/docker-compose-detail.md#verify-installed-library-version`.
