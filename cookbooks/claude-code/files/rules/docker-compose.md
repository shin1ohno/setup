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

Origin: 2026-04-27 — deployed weave-web from a branch missing an open server-logic PR, regressing dispatch.

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

Origin: 2026-05-05 lxc-roon-mcp — mounted `${home}/.config/roon-rs:/root/.config/roon-rs:rw` while container ran UID 1000 / `HOME=/`; app wrote to `/.config/roon-rs/` (unwritable), bind-mount caught zero writes, `roon_api::registry: Failed to persist token: Permission denied (os error 13)` per handshake. Fixed via `/var/lib/roon-mcp/state` + `XDG_CONFIG_HOME=/data`.

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

Origin: 2026-05-06 — dashboard had `"uid": "prometheus"` refs but provisioning yaml omitted explicit `uid:`; every panel "No data" until `uid: prometheus` pinned + `docker restart monitoring-grafana`.

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

Origin: 2026-05-07 — 2.9.10 + bridge net got 0 entries; fixing net still got 0; bumping to 3.6.10 immediately incremented `syslog_target_entries_total`. The UDP issue is a Promtail 2.9 regression, not a config bug.

## `docker import` hang post image-creation + `removal in progress` recovery

`docker export <CID> | docker import - <tag>` can hang indefinitely AFTER the new image already appears in `docker images`. The CLI is blocked waiting on the dockerd API socket; the image itself is committed and persistent. Symptom:

- `docker images <tag>` shows the new image with correct size
- `docker import` process is in state `S` (sleeping) on a socket fd
- dockerd log shows `image created sha256:... tag=<tag>` followed by `failed to validate image signature` (cosmetic post-create check that doesn't block image use)
- The CLI never returns

Recovery — kill the client, then check for cascaded dockerd state damage:

```bash
# 1. Confirm the image exists before killing the CLI
docker images <tag>
# → tag should be listed with non-zero size

# 2. Kill the import process (and any parent build script under set -e)
pkill -f "docker import.*<tag>"

# 3. The source container (`docker create` output) is often left in
#    "removal in progress" state, blocking subsequent `docker rm -f`:
#    Error: removal of container <id> is already in progress
docker rm -f <CID>
# → if blocked, the only reliable fix is restart dockerd:
systemctl restart docker

# 4. Verify the imported image survived the daemon restart
docker images <tag>

# 5. Tag the image with the desired final name and clean up the
#    intermediate (build.sh would have done this if it hadn't been killed)
docker rmi <tag>:tmp
echo "<upstream-digest>" > <stamp-file>
```

Side effect of `systemctl restart docker`: every running container is restarted. Containers with `restart: unless-stopped` come back automatically (~30s); manual `docker compose up -d` may be needed for others.

**Detection signal** during a flatten build: `docker import` etime > 10 minutes with the image already visible in `docker images`. The export side (`docker export`) typically completes within 2-3 minutes for a 10GB layer; if export PID is gone but import etime keeps growing, the import is stuck.

Origin: 2026-05-09 cognee-mcp:cpu flatten — image created within minutes but CLI hung 10+ min on the API socket; container stuck in "removal in progress", `systemctl restart docker` the only path forward. Flattened image survived the restart.

## PyTorch 2.7+ — CUDA libs required even for CPU-only inference

PyTorch ≥ 2.7 ships `libtorch_global_deps.so` which dynamically links against `libcublasLt.so` and other `nvidia-*-cu12` runtime libraries via `ctypes.CDLL` at module import time. The `__init__.py` calls `_preload_cuda_deps()` from an OSError handler when the global-deps shared object fails to load, and the recovery path searches `sys.path` for the bundled nvidia wheels. If they're absent, `import torch` fails before `torch.cuda.is_available()` can return False:

```
ValueError: libcublasLt.so.*[0-9] not found in the system path
```

This means `pip uninstall nvidia-cublas-cu12 nvidia-cudnn-cu12 ...` to slim a CPU-only inference image **breaks `import torch` entirely**, even when the workload never touches CUDA. There is no env var to skip the preload (`TORCH_DEVICE_BACKEND_AUTOLOAD` controls a different feature — extension auto-loading, not CUDA preload).

The CPU-only `+cpu` wheels that historically had this preload code stripped at build time stop at torch 2.6.0 on the pytorch.org `whl/cpu/` index. For torch 2.7+ the only CPU-compatible install is the regular wheel WITH the nvidia deps kept on disk (where they sit unused at runtime).

**Safe slim strategy for cognee-style ML containers**:

- ✓ Uninstall `triton` (~640MB) — GPU kernel JIT compiler with no runtime path from `import torch` on CPU
- ✗ Do NOT uninstall any `nvidia-*-cu12` packages (cublas, cudnn, cufft, curand, cusolver, cusparse, nccl, nvtx, etc.) — torch import depends on their `.so` files being on disk
- ✓ For maximum size reduction, flatten via `docker export | docker import` to collapse Dockerfile layer history (e.g. eliminates `chown -R` copy-up duplicates) — this is where the real wins are, not from package removal

**Build-time validation** to catch a regression before shipping the image:

```dockerfile
RUN /app/.venv/bin/uv pip uninstall --python /app/.venv/bin/python triton \
 && python3 -c "import torch; print('torch', torch.__version__, 'cuda_avail:', torch.cuda.is_available())"
```

The `python3 -c "import torch"` step fails the build if the slim broke the import, before flatten or push.

Origin: 2026-05-09 cognee-mcp:cpu — uninstalling all 15 `nvidia-*-cu12` + triton + torch then reinstalling torch via `--index-url whl/cpu/` failed (no torch 2.10.0 +cpu wheel); keeping torch still failed import (`_preload_cuda_deps` couldn't find the uninstalled libs). Working strategy: keep nvidia libs, uninstall only triton, flatten for the size win (22.4GB → 4.59GB).

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

When upgrading a Python ML/data service that ships both a DB schema migration AND a native extension (lancedb, faiss, hnswlib, torch, sentencepiece), run a throwaway-environment preflight BEFORE touching the production database or container:

1. Restore a `pg_dump` of the production DB into a throwaway Postgres container.
2. Run the new image against the throwaway DB: migrations / setup.py / first-boot init.
3. Probe native extensions at import time on the SAME CPU as production:
   ```bash
   docker exec <new-container> python3 -c "import lancedb; import cognee; print('OK')"
   ```
   SIGILL here = native code compiled for AVX2/AVX-512, absent on the production host. The image that passed CI on a modern cloud runner will crash on an Ivy Bridge Xeon at runtime.
4. Inspect the migration diff and confirm reversibility before proceeding.

**CPU-instruction-set detection** — check the production host before any upgrade involving lancedb, faiss, annoy, or similar ANN libraries:

```bash
grep -oE 'avx2|avx512|sse4_2' /proc/cpuinfo | sort -u
```

If `avx2` is absent and the library bumped its minimum target, the upgrade will SIGILL at import time regardless of what CI reports.

**Detection signal**: `Illegal instruction` in container logs immediately after `import <library>`, not during inference. Always import-time.

Origin: 2026-06-08 cognee 0.5.8→1.0.9 — throwaway-postgres preflight caught a lancedb SIGILL on the Xeon E5-1650 v2 (Ivy Bridge, no AVX2) before the production DB migration ran. Runtime mitigation: `VECTOR_DB_PROVIDER=pgvector` + API mode keep lancedb's import off the boot path.

## Verify Actual Installed Library Version Before Debugging

When debugging a Python service running in a container, the image tag identifies the **wrapper/server package**, not the underlying library version. These diverge because:

- The server package specifies a dependency range (`cognee>=1.0.0`), not a pin
- `:latest` rebuilds when upstream wheels change, silently changing the library version
- `uv.lock` may pin an older version than `pyproject.toml` intends if not regenerated at tag time

**Before debugging any Python-library-based service**, verify the actual runtime version:

```bash
docker exec <container> python3 -c "import <library>; print(<library>.__version__)"
# e.g.: docker exec cognee python3 -c "import cognee; print(cognee.__version__)"
```

If the version differs from your assumption (image tag, git tag, or last session), **all debug output from prior sessions may be non-reproducible** — API signatures, error messages, and behavior differ across library versions.

**When building from a git tag**: confirm the lockfile version:

```bash
grep 'name = "<library>"' uv.lock -A2 | grep version
```

If it's older than `pyproject.toml` specifies, regenerate: `uv lock`.

**Baseline invariant for multi-turn debug sessions**: record `<library>.__version__` at the start of each turn where library behavior is the subject. A different version from the previous turn means the container was rebuilt and prior observations no longer apply.

Origin: 2026-06-08 cognee upgrade — three distinct `server.py` generations under the same cognee-mcp 0.5.4, and `cognee/cognee-mcp:latest` drifted cognee 1.0.4→1.1.0 between sessions, making prior debug observations non-reproducible.
