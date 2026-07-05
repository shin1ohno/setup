# PVE LXC Operational Gotchas — Examples & Origin Notes

On-demand detail for `~/.claude/rules/pve-lxc.md`. Read a section when the summary points here.


## bind-mounts-terraform-import

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

Origin: 2026-05-06 monitoring CT 111 — bind-mount apply failed twice.

## rootfs-zfs-refquota

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

Origin: 2026-05-09 cognee shrink 32G→8G on CT 105 — df still showed 32G.

## privileged-lxc-namespace

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

Origin: 2026-05-06 — privileged CT 100 (roon) node-exporter stuck `activating`.

## iam-attach-eventual-consistency

## IAM policy attachment — ~60s eventual consistency before the first probe

After `aws iam attach-user-policy` / `put-user-policy` / `put-role-policy` (or a
`terraform apply` that adds an IAM grant) returns success, wait ~60s before the
first call that depends on the new permission. Probing immediately returns
`AccessDeniedException` even though the attachment succeeded — IAM propagation
is eventually consistent.

```bash
aws iam attach-user-policy --user-name X --policy-arn arn:...
sleep 65   # IAM eventual consistency — do NOT diagnose the AccessDenied yet
pct exec <vmid> -- bash -lc "aws ssm get-parameter --name /path --profile X"
```

If the policy ARN / region / principal are correct, an immediate `AccessDenied`
is a timing artifact — the fix is to wait, not to change the policy. Re-diagnose
only if it persists past ~2 min.

Origin: 2026-06-13 case-B IAM grant (pve-bootstrap-ssm → /hydra/* + kms:Decrypt) — AccessDenied immediately, DECRYPT_OK ~60s later on CT 110.
