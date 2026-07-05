---
description: "Tailscale operational gotchas — accept-routes vs LAN supernet conflict on host-routers"
---

# Tailscale Operational Rules

## Tailscale `accept-routes=true` + Kernel Policy Routing Conflict

When a host enables `tailscale set --accept-routes=true` while also serving as a LAN router or gateway, Tailscale injects peer-advertised routes into kernel **routing table 52**, selected by `ip rule 5270: from all lookup 52` — which is consulted **before** the main table. If any tailnet peer advertises a supernet that overlaps with the host's own LAN CIDR (classic example: `hnd-subnet-router` advertises `192.168.0.0/16` while the host's eth0 is on `192.168.1.0/24`), every reply from the host to a LAN address gets routed via `tailscale0` instead of `eth0`. Local connectivity silently breaks; SSH from LAN, intra-LAN HTTP probes, and reverse-proxy upstream reachability all start timing out.

Diagnosis:

```
ip rule show           # confirm `5270: from all lookup 52` is present
ip route show table 52 # see which peer routes Tailscale injected
```

Fix: drop the conflicting supernet from table 52 (and from main, if also present):

```
ip route del <conflicting-cidr> dev tailscale0 table 52 || true
ip route del <conflicting-cidr> dev tailscale0 || true
```

Codify in a oneshot systemd unit so the cleanup re-runs on every tailscaled restart / LXC reboot. Reference cookbook: `cookbooks/lxc-pro-router/default.rb` (PR #115, 2026-05-04). The remaining peer routes (`10.33.128.0/18` for AWS VPC, `100.64.0.0/10` for tailnet CGNAT) are safe to keep — only LAN supernets cause the conflict.

Detection signal: LAN reachability to the Tailscale router host suddenly drops the moment `accept-routes=true` is set, even though all other Tailscale functionality (subnet advertise, peer ping) keeps working. The asymmetry is the tell.
