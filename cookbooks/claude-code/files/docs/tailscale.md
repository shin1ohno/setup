---
description: "Tailscale operational gotchas — accept-routes vs LAN supernet conflict on host-routers, and LAN-wide DHCP option 121 hijacking another tailnet's CGNAT"
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

## LAN-wide DHCP option 121 hijacks a *different* tailnet's CGNAT

A LAN whose DHCP server advertises `100.64.0.0/10` (RFC-3442 classless static routes, option 121) toward a local subnet router breaks every DHCP client that is itself a node on a **different** tailnet. CGNAT is per-tailnet address space, but option 121 is scope-wide and the server cannot know which tailnet a receiving client belongs to — so the client installs a LAN route covering the whole of `100.64/10`, it wins over the client's own `utun`/`tailscale0` route, and the client's entire tailnet resolves to the LAN's subnet router. The symptom looks exactly like a dead peer: `ssh <peer>` returns `No route to host` while MagicDNS still resolves the name, and pings to the peer's tailnet IP leak to the LAN gateway and come back as `Redirect Host` / `Time to live exceeded`. Every peer on that tailnet is equally unreachable, which is the signal that separates this from a single expired node key. A VPC/remote-subnet entry in the same option 121 list is fine and should stay: a remote subnet has no other path, whereas CGNAT belongs to the tailnet nodes themselves — a host that needs it should become a node, and once it is one the LAN route only overwrites its own.

Diagnosis (run these as the user or with the sandbox disabled — `route`, `sysctl`, and `networksetup` return `Operation not permitted` inside Claude's command sandbox, and ICMP is blocked there too, so a sandboxed `ping` looks like a network failure):

```
ipconfig getpacket en0 | grep -i classless   # macOS: what option 121 actually delivered
route -n get <peer-tailnet-ip>               # `interface: en0` = hijacked, `utun*` = healthy
netstat -rn -f inet | grep '100.64'          # two 100.64/10 rows = the conflict
netstat -rn -f inet | grep '10.33.128'       # positive control: same grep shape returns non-zero
ip route get 100.64.0.1                      # Linux equivalent of the route lookup
```

Fix at the DHCP server, not on the client — drop the CGNAT entry from the scope's classless static routes and keep the remote-subnet entry (home-monitor `rtx_dhcp_scope.ebisu_main`, PR #130). Client-side workarounds exist but none is durable: deleting the route by hand returns on the next DHCP renew, and enabling an exit node only wins because it demotes the `en0` routes to `IFSCOPE` — at the cost of routing all egress through the exit node, and it needs `--exit-node-allow-lan-access=true` or LAN hosts become unreachable. macOS has no supported way to ignore one option-121 entry (`ipconfig` has no such command, `networksetup` only offers additive `-setadditionalroutes`, and no `ExcludedRoutes`-style key exists in configd).

```
sudo route -n delete -net 100.64.0.0/10 <lan-gateway>   # stopgap only; DHCP renew restores it
```

Codify the invariant next to the DHCP scope declaration: never put a tailnet's own address space in option 121, and hand CGNAT to static-IP hosts through a tailscale0-guarded systemd oneshot instead (`cookbooks/lan-vpc-route`). The comment is load-bearing because the RTX Terraform provider never reads option 121 back from the device, so an out-of-band re-addition does not appear in `terraform plan`. After changing the server, force a renew (`sudo ipconfig set en0 DHCP`) before trusting the result — a 72h lease with a 36h T1 otherwise hides the fix for up to a day and a half — and if an exit node was masking the problem, renew first and turn the exit node off second.

Detection signal: MagicDNS resolves a tailnet peer's name but every peer on that tailnet is unreachable, and `route -n get <peer-ip>` names a LAN interface. A single expired node key takes down one peer; a hijacked CGNAT prefix takes down all of them at once.
