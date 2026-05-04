#  setup

## Entry recipe by host type

Pick the entry recipe that matches the target host. Running the wrong
one is now a hard failure for `linux.rb` — it refuses to apply inside
any container — so the right one matters.

| Host type | Example | Entry recipe | What it installs |
|---|---|---|---|
| Physical Linux workstation | `pro` (Mac Pro 5,1) | `linux.rb` | Standard roles + physical-hardware cookbooks (broadcom-wifi, bluez, zeroconf, edge-agent, arp-flux). MCP servers and Roon are NOT here — they live in their own LXCs |
| Proxmox VE host | the PVE host that hosts the LXCs | `pve-host.rb` | Minimal: bridges + arp-flux + tailscaled |
| Developer workstation LXC | `pro-dev` (CT 104), future `*-dev` | `lxc-pro-dev.rb` (delegates to `lxc-dev-workstation` cookbook) | Standard roles minus hardware cookbooks. New dev LXCs follow the same shape — set `node[:lxc_dev][:hostname]` / `:tailscale_ssm_key` and include the cookbook |
| Service LXC | `lxc-cognee`, `lxc-hydra`, `lxc-memory`, `lxc-roon`, `lxc-roon-mcp`, `lxc-weave`, `lxc-samba`, `lxc-housekeeping`, `lxc-consent`, `lxc-pro-router` | matching `lxc-<service>.rb` | Service-specific (existing) |
| macOS | `air`, `ohnos-macbook` | `darwin.rb` | macOS dev environment + mac-apps |

Override the `linux.rb` container guard with `MITAMAE_FORCE_BARE_METAL=1`
only if `systemd-detect-virt -c` misclassifies a genuine bare-metal host.

## darwin

1. Install git (hit `git` and you are asked to install it)
2. Install Rosetta 2: `softwareupdate --install-rosetta`
3. Download or clone this repository and `./bin/setup`  to install mitamae
4. `./bin/mitamae local darwin.rb`
5. Install [Twingate](https://apps.apple.com/jp/app/twingate/id1501592214?l=en&mt=12) etc. from AppStore manually

## Interactive bootstrap (first-time machine)

The cookbook expects an interactive TTY on first run. It pauses for AWS auth and any sudo prompts; otherwise everything is wired up by ordering (the `ssh-keys` cookbook places the device's private key, registers a `Host github.com` stanza, and downstream cookbooks that need GitHub access depend on it).

**Prerequisite (one-time, before running on this machine):**

The new device's public key must already be registered to https://github.com/shin1ohno via home-monitor's Terraform (`github_user_ssh_key.device[*]`). Run `terraform apply` in `home-monitor/` if you've added a new device to `local.ssh_devices`.

**Pause points during the run:**

- **AWS CLI auth** (gates `ssh-keys` and the SSM-fetching cookbooks: `ingest-drop`, `cognee`, `hydra`, `ai-memory`, `codex-cli`, `mcp`)
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
