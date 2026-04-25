#  setup

## darwin

1. Install git (hit `git` and you are asked to install it)
2. Install Rosetta 2: `softwareupdate --install-rosetta`
3. Download or clone this repository and `./bin/setup`  to install mitamae
4. `./bin/mitamae local darwin.rb`
5. Install [Twingate](https://apps.apple.com/jp/app/twingate/id1501592214?l=en&mt=12) etc. from AppStore manually

## Interactive bootstrap (first-time machine)

The cookbook expects an interactive TTY on first run. It pauses at three points for you to complete external setup, then continues:

- **AWS CLI auth** (before cookbooks like `ingest-drop`, `cognee`, `hydra`, `ai-memory`, `codex-cli`, `mcp`)
  ```
  aws configure                              # default profile
  # OR
  aws configure --profile <name>
  export AWS_PROFILE=<name>                  # for the running mitamae shell
  ```
  Run in another terminal, then return and press Enter to resume.

- **GitHub SSH access** (before cookbooks like `dot-tmux`, `managed-projects`)
  - The `ssh-keys` cookbook (in core role) places `~/.ssh/<host>_ed25519`
  - Add the matching `*.pub` to https://github.com/settings/keys
  - Test: `ssh -T git@github.com` should say "successfully authenticated"
  - Then return and press Enter to resume.

- **sudo password** (e.g. `pm2 startup launchd`, `mac-apps fdautil`, `zsh chsh`)
  - Just type your password when prompted. No external setup needed.

After the first successful bootstrap, every subsequent `./bin/mitamae local darwin.rb` runs straight through with no prompts (the `await_external_auth` checks pass immediately).

If you've already configured everything before invoking mitamae, you'll never see the prompts.
