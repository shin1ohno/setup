#  setup

## Quick start (new machine)

Pick the column that matches the target. Each step assumes you start in the repo root after `git clone`.

| Step | macOS | Bare-metal Linux | PVE host |
|---|---|---|---|
| 0. Prereq | `softwareupdate --install-rosetta` (Apple Silicon)<br>install git via xcode-select | — | fresh PVE 9.x install |
| 1. Fetch mitamae | `./bin/setup` | `./bin/setup` | `./bin/setup` |
| 2. Apply | `./bin/mitamae local darwin.rb` | `./bin/mitamae local linux.rb` | `./bin/mitamae local pve/pve-host.rb` |
| 3. First-run pauses | AWS CLI auth + sudo password (see [Interactive bootstrap](#interactive-bootstrap-first-time-machine)) | same | AWS CLI auth |
| 4. Manual extras | install AppStore apps (Twingate etc.) | — | — |

**Prereq for any host**: the device's public key must already be registered to GitHub via `home-monitor/` Terraform (`github_user_ssh_key.device[*]`) — `ssh-keys` cookbook fetches the matching private key from SSM during step 2.

**LXC fleet** (dev workstation + service LXCs): provision each CT via `home-monitor/` Terraform, seed AWS creds with `./bin/bootstrap-lxc-creds <CT>` from the PVE host, then apply all `pve/lxc-*.rb` in parallel with `./bin/apply-pve-lxcs`. Per-LXC details in the table below.

## Entry recipe by host type

Pick the entry recipe that matches the target host. Running the wrong
one is now a hard failure for `linux.rb` — it refuses to apply inside
any container — so the right one matters.

| Host type | Example | Entry recipe | What it installs |
|---|---|---|---|
| Physical Linux workstation | `pro` (Mac Pro 5,1) | `linux.rb` | Standard roles + physical-hardware cookbooks (arp-flux, bluez, zeroconf, broadcom-wifi, edge-agent) + elastic-agent. MCP servers and Roon are NOT here — they live in their own LXCs |
| Proxmox VE host | the PVE host that hosts the LXCs | `pve/pve-host.rb` | Minimal hypervisor stack: `pve-host` (bridges + arp-flux), `ssh-keys`, `lxc-core` (node-exporter + auto-mitamae-target), elastic-agent |
| Developer workstation LXC | `pro-dev` (CT 104), future `*-dev` | `pve/lxc-pro-dev.rb` (delegates to `lxc-dev-workstation` cookbook) | Standard roles minus hardware cookbooks. New dev LXCs follow the same shape — set `node[:lxc_dev][:hostname]` / `:tailscale_ssm_key` and include the cookbook |
| Service LXC | `lxc-cognee`, `lxc-hydra`, `lxc-memory`, `lxc-monitoring`, `lxc-roon`, `lxc-roon-mcp`, `lxc-weave`, `lxc-samba`, `lxc-housekeeping`, `lxc-consent`, `lxc-pro-router`, `lxc-es-0`/`lxc-es-1`/`lxc-es-2` (Elasticsearch cluster), `lxc-kibana`, `lxc-apm-server` | matching `pve/lxc-<service>.rb` | Service-specific (existing). Apply all PVE-virtualized LXCs in parallel via `bin/apply-pve-lxcs` |
| macOS | `air`, `ohnos-macbook` | `darwin.rb` | macOS dev environment + mac-settings, mac-apps, macism, altserver, gpg-backup, edge-agent, elastic-agent, macos-hub |

Override the `linux.rb` container guard with `MITAMAE_FORCE_BARE_METAL=1`
only if `systemd-detect-virt -c` misclassifies a genuine bare-metal host.

## Interactive bootstrap (first-time machine)

The cookbook expects an interactive TTY on first run. It pauses for AWS auth and any sudo prompts; otherwise everything is wired up by ordering (the `ssh-keys` cookbook places the device's private key, registers a `Host github.com` stanza, and downstream cookbooks that need GitHub access depend on it).

**Prerequisite (one-time, before running on this machine):**

The new device's public key must already be registered to https://github.com/shin1ohno via home-monitor's Terraform (`github_user_ssh_key.device[*]`). Run `terraform apply` in `home-monitor/` if you've added a new device to `local.ssh_devices`.

**Pause points during the run:**

- **AWS CLI auth** (gates `ssh-keys` and the SSM-fetching cookbooks: `mcp`, `codex-cli`, `ingest-drop`, `edge-agent`, `elastic-agent`. `cognee` / `hydra` / `ai-memory` / `roon-mcp` have migrated to their own LXCs and gate auth there)
  ```
  aws configure                              # default profile
  # OR
  aws configure --profile <name>
  export AWS_PROFILE=<name>                  # for the running shell
  ```
  Run in another terminal, then return and press Enter to resume.

- **sudo password** (e.g. `pm2 startup launchd`, `mac-apps fdautil`, `zsh chsh`)
  - Just type your password when prompted.

After the first successful bootstrap, every subsequent run goes straight through (the auth checks pass immediately).
