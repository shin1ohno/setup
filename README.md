#  setup

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
