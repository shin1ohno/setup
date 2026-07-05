---
description: "PVE LXC operational gotchas — bind mounts, terraform import, pct exec TTY semantics, privileged-vs-unprivileged systemd hardening"
---

# PVE LXC Operational Gotchas

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/pve-lxc-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

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

Origin: 2026-05-09 ES+Kibana docker-compose — 4 docker-ism bugs.

## PVE LXC — Bind Mounts and `terraform import`

Detail: see `~/.claude/docs/pve-lxc-detail.md#bind-mounts-terraform-import`.

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

Origin: 2026-05-06 monitoring CT 111 — `/data/monitoring/{prometheus,grafana}` root:root crash-loop.

## `pct set -rootfs size=` does not propagate to ZFS refquota

Detail: see `~/.claude/docs/pve-lxc-detail.md#rootfs-zfs-refquota`.

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

Origin: 2026-05-06 Phase 3a — `pct exec` "TTY apply" framing hid manual aws-configure prereq.

## Privileged PVE LXC — systemd unit hardening directives fail with `status=226/NAMESPACE`

Detail: see `~/.claude/docs/pve-lxc-detail.md#privileged-lxc-namespace`.

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

Origin: 2026-05-10 cognee leak — 3 guessed FQDNs before `ssh root@192.168.1.10` (pve-host = pro).

## `pct exec` spawns a non-login shell — use `bash -lc` for profile.d tools

`pct exec <vmid> -- aws ssm get-parameter ...` (or any tool installed via
profile.d — mise, pyenv, cargo, the awscli binary in `/usr/local/bin`) fails
with `Failed to exec <tool>` because `pct exec` spawns `/bin/sh` WITHOUT sourcing
login profiles, so `/usr/local/bin` and the user's shim dirs are not on PATH.

Fix — wrap the command in a login shell:

```bash
pct exec <vmid> -- bash -lc "aws ssm get-parameter --name /path ... --profile X"
```

`bash -l` sources `/etc/profile` + `/etc/profile.d/*.sh`, which populates PATH
for the installed tools. Without `-l` only the base OS PATH is visible.

This is PATH-only, NOT a TTY — it does not interact with the separate
`STDIN.tty?`-returns-false behavior documented above (`-l` grants PATH, not a
terminal).

Origin: 2026-06-13 case-B — `pct exec 110 -- aws ssm` got `Failed to exec aws`; `bash -lc` resolved it.

## IAM policy attachment — ~60s eventual consistency before the first probe

Detail: see `~/.claude/docs/pve-lxc-detail.md#iam-attach-eventual-consistency`.
