---
description: "PVE LXC operational gotchas — bind mounts, terraform import, pct exec TTY semantics, privileged-vs-unprivileged systemd hardening"
---

# PVE LXC Operational Gotchas

## Design gate: Docker-in-LXC vs apt+systemd (NEW LXC service)

Before writing a new `pve/lxc-<service>.rb` recipe with docker-compose, ask via AskUserQuestion: should this service run via docker-compose or directly via apt-get + systemd unit?

Docker-in-LXC reliably produces this bug class:

- **bind-mount UID mismatch**: container UID 1000 vs host LXC unprivileged UID mapping (100000 offset) vs cookbook chown — TLS cert / data dir ownership all need explicit cross-layer chown
- **container netns vs host LXC netns**: container can't bind LXC IP, requires `network.bind_host: 0.0.0.0` + `network.publish_host: <LXC IP>` split
- **docker-proxy port-forward silently drops some (port, transport) combinations** (UDP / 9300 between same-subnet LXCs in 2026-05-09 session — 9200 worked through the same DNAT shape, 9300 had pkt-count = 0)
- **`.env` shell-interpretation collision**: docker-compose `env_file:` reads raw KEY=VALUE, but bash `source` interprets metacharacters in values — Terraform random_password values regularly contain `(` `)` `[` `&` etc.
- **container restart lag in apply cycle**: `docker compose down + up` race conditions vs cookbook `notifies` chain
- **healthcheck `${VAR}` substitution unsafe**: docker-compose substitutes raw value, then shell parses as command → metacharacters break

Reserve docker-compose for genuinely multi-container stacks (e.g. monitoring with prometheus + grafana + vector + 3 exporters). For single-purpose service LXCs (1 service per CT), prefer apt-get + systemd unit:

- env vars: systemd `EnvironmentFile=` (no shell source, metacharacter-safe)
- log: journalctl-integrated
- TLS cert install: standard `/etc/<service>/certs/`, systemd `User=<service>`
- network: LXC interface direct bind, no port forward layer
- memlock: LXC `lxc.prlimit.memlock unlimited` inherits naturally
- no 1.4 GB image pull on every fresh CT

This rule exists because the 2026-05-09 ADR-0005 Phase 3b session lost ~5 hours debugging an ES + Kibana docker-compose deployment. 4 of 8 cookbook bugs were direct docker-isms (`.env` source collision, ES_TMPDIR image-internal path, network bind/publish split, docker-proxy 9300 drop). LXC native install would have made all 4 structurally impossible. The user surfaced the design question mid-session ("なんで Docker を使ってるんでしょう？") — it belonged at plan time.

## PVE LXC — Bind Mounts and `terraform import`

`mount_point` blocks with `volume = "/<host-path>"` (which PVE treats as `type = bind`) **cannot be created via the bpg/proxmox provider when authenticating with an API token**, regardless of the token's role (PVEAdmin included). PVE's source-level check is literal:

```perl
# from PVE/LXC/Config.pm
if ($mp->{type} eq 'bind' && $authuser ne 'root@pam') {
    die "mount point type bind is only allowed for root\@pam\n";
}
```

The check uses string equality on `$authuser`, so `root@pam!terraform` (a token of root@pam) does NOT pass. This trap is invisible at plan time because existing bind-mounted LXCs (cognee/weave/memory) are in TF state — their `terraform plan` output is clean — but they entered state via `pct create` on the PVE host as root@pam followed by `terraform import`, NOT via TF-managed creation.

**Workflow for a new LXC with bind mounts**:

1. Build the `pct create` command from the TF spec (cores, memory, disk, network, mounts, features.nesting, unprivileged, startup, ssh-public-keys, password). Use `pct config <existing-similar>` as a reference template.
2. Run on PVE host as root@pam: `pct create <vmid> <template> <flags...>`
3. `pct set <vmid> --startup order=N,up=M,down=K` separately — the `--startup` flag during `pct create` silently doesn't take effect (bpg/proxmox quirk; verified by inspecting `pct config` post-create).
4. `terraform import 'proxmox_virtual_environment_container.lxc["<name>"]' <node>/<vmid>` — the import address format for bpg/proxmox is **`<node>/<vmid>`** (e.g. `pro/111`), not bare `vmid`.
5. Run `terraform plan`. The plan WILL show `forces replacement` on `initialization` (write-only `user_account.{keys,password}`) and `operating_system.template_file_id` (PVE doesn't expose the post-extract template path via API). This is permanent drift; the post-import LXC cannot be reconciled in-place.
6. **Add `lifecycle { ignore_changes = [initialization, operating_system, mount_point] }`** to the for_each container resource (or to the specific resource if not in for_each). Document with a comment naming the three drift sources.
7. Re-plan: should now show only the IAM/SSM/network adds + an in-place update for `start_on_boot` / `started`. No destroys.

**State-archaeology check before designing**: if the new LXC needs a bind mount, run `terraform state show 'proxmox_virtual_environment_container.lxc["<existing-with-bind-mount>"]'` first. The presence of the bind mount in state with no plan diff confirms the manual-create + import convention is the established path. Do NOT default to "let TF create it" — the API token's permission ceiling makes this fail at apply time, costing one or more apply-retry cycles.

This rule exists because the 2026-05-06 PR #15 (home-monitor monitoring LXC) terraform apply failed twice on `mount point type bind is only allowed for root@pam` before the API-token-vs-root@pam constraint was confirmed by reading PVE source. Recovery required a hotfix PR (#17) adding `lifecycle.ignore_changes`, plus manual `pct create 111` + `terraform import pro/111`. The full sequence cost ~45 min that would have collapsed to ~5 min if the state-archaeology check at plan time had surfaced the convention.

## Unprivileged LXC Bind-Mount Host Ownership Mapping

In an unprivileged PVE LXC, container UID/GID are mapped to a high host range (default offset **100000**, so container UID 0 = host UID 100000, container UID 1000 = host UID 101000, container UID 65534 = host UID 165534, etc.). Host directories used as bind-mount targets must be owned by the host UID that maps to the in-container UID the cookbook expects.

**The trap**: a cookbook resource

```ruby
directory "/data/<service>" do
  owner "root"
  group "root"
end
```

will fail at converge time with `chown: changing ownership of '/data/<service>': Operation not permitted` when:

1. The container is unprivileged.
2. `/data/<service>` is a bind mount of a host directory (e.g. `/mnt/data/<service>`).
3. The host directory's owner does NOT map to UID 0 inside the container.

The cookbook's `chown` runs inside the container as in-namespace root. In-namespace root has CAP_CHOWN over files owned by *mapped* UIDs (100000–165535 by default). It cannot chown files owned by host UIDs **outside** that range — including host root (UID 0), which maps to nobody (UID 65534) inside the container.

**Pre-bootstrap step on the PVE host** (run once per new bind mount, as root@pam):

```bash
mkdir -p /mnt/data/<service>
chown 100000:100000 /mnt/data/<service>   # container root
chmod 755 /mnt/data/<service>
```

This makes the directory appear as `root:root` (UID 0) inside the container, so the cookbook's `directory ... owner "root"` resource is a no-op (no chown attempt).

**Subdirectories for non-root container processes**: services like Prometheus (runtime UID 65534 / `nobody`) and Grafana (runtime UID 472 / `grafana`) need their data subdirectories owned by their respective container UIDs. The cookbook can create the subdirectory and chown to those UIDs inside the container (in-namespace root has CAP_CHOWN over UIDs in the mapped range, which covers 0–65535 inside ↔ 100000–165535 on host). Example:

```ruby
# Inside the container, these UIDs map cleanly to host UIDs 165534 and 100472.
directory "/data/<service>/prometheus" do
  owner "65534"   # nobody (Prometheus runtime user)
  group "65534"
  mode "755"
end

directory "/data/<service>/grafana" do
  owner "472"     # grafana runtime user
  group "472"
  mode "755"
end
```

If the cookbook omits explicit owners for subdirectories, the bind-mount target ends up `root:root` inside the container, and the docker container processes (running as non-root) crash-loop with `Permission denied` on first write — visible in `docker logs <container>` but invisible to mitamae which already declared the directory resource "successful".

**Detection signal**: docker container restarting on an unprivileged-LXC bind-mount with logs showing `Permission denied` / `mkdir: ... not writable` → host directory owner doesn't match the container runtime UID. Fix path: chown the bind-mount subdirectory inside the container (`pct exec <vmid> -- chown -R <runtime-uid>:<runtime-uid> /data/<service>/<subdir>`) then `docker compose restart`.

This rule exists because the 2026-05-06 monitoring CT 111 first mitamae apply created `/data/monitoring/{prometheus,grafana}` as `root:root` inside the container; both Prometheus (UID 65534) and Grafana (UID 472) crash-looped on first write. Recovery: in-container chown to the correct runtime UIDs, then `docker compose restart`. Plan time should have included an explicit `directory` resource per service subdirectory with the runtime UID. Dry-run on the dev box hides this because the dev box is privileged Linux without UID mapping.

## `pct set -rootfs size=` does not propagate to ZFS refquota

When resizing (shrink or grow) an LXC root disk on a ZFS-backed PVE host, `pct set <vmid> -rootfs <vol>,size=<N>G` updates the PVE config but does NOT update the ZFS dataset's `refquota`. The CT continues to see the old size via `df -h /` until the ZFS quota is set explicitly.

Two-step is always required — `pct set` alone is insufficient:

```bash
# Confirm the dataset name from PVE config
pct config <vmid> | grep ^rootfs
# → e.g. rootfs: local-zfs:subvol-105-disk-0,size=8G

# Apply the ZFS quota separately (replace <N> and <vmid>)
zfs set refquota=<N>G rpool/data/subvol-<vmid>-disk-0

# Verify both layers report the same value
zfs get -H -o value refquota rpool/data/subvol-<vmid>-disk-0
pct exec <vmid> -- df -h /
```

**Detection signal**: `pct config <vmid>` reports the new size, but `df -h /` inside the CT reports the old size. The mismatch persists across `pct stop` / `pct start` cycles because `df` reflects the ZFS quota, which `pct set` does not touch.

**Order of operations for shrink** (must be before quota change so `used > target` doesn't briefly violate the quota):

1. `pct exec <vmid> -- bash -c 'cd /path/to/compose && docker compose down'` (clean stop)
2. `pct stop <vmid>`
3. `pct set <vmid> -rootfs <vol>,size=<N>G` (PVE config)
4. `zfs set refquota=<N>G rpool/data/subvol-<vmid>-disk-0` (ZFS quota)
5. `pct start <vmid>`
6. Verify `df -h /` reports the new size

For grow, the order is the same but the quota change is online-safe (CT can be running). Recovery from a too-small shrink is one-liner: `zfs set refquota=<larger>G rpool/data/subvol-<vmid>-disk-0` + sync `pct set` config. ZFS refquota grow takes effect immediately.

This rule exists because the 2026-05-09 cognee disk shrink (32G → 8G) had `pct set -rootfs ...,size=8G` succeed silently, but `df -h /` inside CT 105 still showed 32G. `zfs get refquota` confirmed PVE only updated its own config, not the underlying ZFS dataset. The fleet-config alignment that motivated the shrink was incomplete until `zfs set refquota` was applied as a second step.

## `pct exec` from `ssh root@<pve-host>` is non-TTY — `STDIN.tty?` returns false

`ssh root@<pve-host> 'pct exec <vmid> -- bash -lc "..."'` does NOT propagate a TTY into the LXC. `STDIN.tty?` inside the inner bash returns `false`, even though the outer ssh session might have one. Plans that assume `pct exec` "is" TTY-equivalent (and therefore that `cookbooks/functions/default.rb` `require_external_auth` will use its TTY-prompted retry path) are wrong.

Concrete impact on `require_external_auth`-gated cookbooks:
- TTY context: `check_command` fails → 5-prompt retry loop → operator unblocks → block runs
- Non-TTY context (which `pct exec` over ssh IS): `check_command` fails → log warn → **block silently skipped** → mitamae continues with the auth-gated work undone

Symptom: cookbook reports apply success but follow-up verify shows the SSM-fetched resource (e.g. `/root/.ssh/authorized_keys` forced-command entry) is missing. Logs contain `[bootstrap] AWS SSM access (profile=<X>, region=<Y>) not configured AND STDIN is not a TTY — skipping auth-gated block.` — easily missed if you only tail the last 10 lines.

**Fix shape — apply once with auth seeded externally**:

For LXC-fleet cookbooks under the auto-mitamae pattern, seed the AWS profile (or whatever credential `require_external_auth` checks) BEFORE the first `mitamae local`. The two reliable channels:

1. **Operator script**: `bin/bootstrap-lxc-creds <CT>` (setup repo, 2026-05-07 onwards) — copies the profile from the PVE host into the fresh LXC via `pct exec` writes
2. **Env vars on first apply**: `AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... ./bin/mitamae local pve/lxc-X.rb`

Then orchestrator-driven subsequent applies have the auth in place and the gated block runs every cycle.

**Forcing TTY via `ssh -tt + pct exec` does NOT work** in our setup (tested 2026-05-06): `pct exec` strips the pty even when ssh allocates one. Don't try to engineer around the non-TTY status.

**Detection**:

```
git grep -nE 'pct exec.*--.*bash -lc' cookbooks/ pve/ docs/  # plans that assume TTY
```

Any plan / doc that talks about `pct exec` as "TTY apply" is suspect — replace the assumption with the seed-auth-then-apply pattern above.

This rule exists because the 2026-05-06 Phase 3a session walked into this assumption: 6 fleet hosts each needed a manual `aws configure set` step BEFORE mitamae apply, and the original plan's `pct exec` "TTY apply" framing didn't surface the prerequisite. Phase 3b/3c re-discovered it; Phase 3c started with an explicit AWS profile probe step (Stage 0) on every new host as a result.

## Privileged PVE LXC — systemd unit hardening directives fail with `status=226/NAMESPACE`

Inside a *privileged* PVE LXC (no `unprivileged: 1`), systemd's namespace-related unit directives fail at `ExecStart` with `Result: exit-code (status=226/NAMESPACE)`. Specifically these directives, all of which trigger systemd's mount-namespace setup:

- `ProtectSystem=strict` (or `=full`)
- `ProtectHome=yes`
- `PrivateTmp=yes`
- `NoNewPrivileges=yes`

Result: `Active: activating (auto-restart) (Result: exit-code)` in a tight 5-sec restart loop, no `Listening on …` log line, the daemon's port never opens. Direct invocation of the same binary from a shell on the same LXC works fine — the failure is purely in systemd's namespace setup colliding with the LXC's cgroup/namespace boundary.

**Drop-in overrides setting these to `=no` did NOT take effect** in our 2026-05-06 testing — `systemctl show` reported the new effective value, but the unit kept failing with the same `status=226/NAMESPACE`. The unit had to ship without the directives in the first place; `=no` overrides via drop-in were not sufficient.

**Detection**:

```
systemctl status <unit> --no-pager | grep -E 'status=226|NAMESPACE|activating'
pct config <vmid> | grep -E '^unprivileged:'   # absent → privileged LXC
```

If the LXC is privileged (no `unprivileged:` line) AND the unit status is `activating (auto-restart)` with `status=226/NAMESPACE`, the hardening is the cause.

**Fix shape**: ship the unit without `ProtectSystem` / `ProtectHome` / `PrivateTmp` / `NoNewPrivileges`. The defense-in-depth value is small for a LAN-internal port, and the operational cost of supporting both privileged and unprivileged LXCs in the fleet outweighs it. See setup PR #164 (`cookbooks/node-exporter/files/node-exporter.service`) for the canonical example.

**When designing new fleet cookbooks that ship systemd units**: assume any LXC in the fleet might be privileged (today only CT 100 roon is, but the rule is "support both"). Skip the namespace-related hardening directives in the cookbook-managed unit; if defense-in-depth is needed for a specific deployment, add a drop-in (which, as noted, may not actually take effect on privileged LXCs — accept the limitation).

This rule exists because setup PR #164 (2026-05-06) was required after Phase 3b apply on CT 100 left node-exporter cycling in `activating` state. CT 100 (roon) is the only privileged LXC in the home fleet (it predates the unprivileged-default convention). The hardening directives shipped fine on every other LXC; only privileged tripped over them.

## PVE / LXC reachability — read the LAN IP from `devices.json`, do not guess FQDNs

`contracts/devices.json` logical names (the JSON key, e.g. `pve-host`, `cognee`, `monitoring`) are identifiers, not hostnames. The routable address for SSH / API / `pct exec` access is the `lxc.ip` or top-level `ip` field of that entry — NOT `<key>.home.local`, `<key>.tailscale.ts.net`, or any other constructed FQDN. The logical name and the machine's `hostname` often diverge (e.g., `pve-host` in devices.json while the machine reports `hostname=pro` and listens on `192.168.1.10`).

Probe before SSH / scp / curl:

```bash
jq -r '.devices["<logical-name>"] | .lxc.ip // .ip // .tailscale.ip // "not found"' \
  ~/ManagedProjects/home-monitor/contracts/devices.json
```

If the result is `not found`, dump the entry's whole structure to find the correct field:

```bash
jq '.devices["<logical-name>"]' ~/ManagedProjects/home-monitor/contracts/devices.json
```

Construct an FQDN only when the entry has an explicit `fqdn` or `tailscale` field — never from the logical name alone. For PVE LXCs specifically, prefer `pct exec <ct_id>` from the PVE host over direct SSH, since LXCs may not have SSH keys provisioned for your user.

This rule exists because the 2026-05-10 cognee leak diagnosis burned three SSH attempts on `pve-host.home.local`, `pve.home.local`, and other guessed FQDNs before discovering that `pve-host` (devices.json logical name) maps to the same machine as `pro` (the bare-metal Linux entry, IP `192.168.1.10`). The correct path was always `ssh root@192.168.1.10` — the IP was right there in `pve-host`'s sibling `pro` entry, not under a constructed FQDN.
