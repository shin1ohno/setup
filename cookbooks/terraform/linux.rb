# frozen_string_literal: true
#
# terraform, linux half: HashiCorp's apt repository. The darwin half installs
# from their Homebrew tap instead (cookbooks/terraform/darwin.rb).
execute "install terraform" do
  # /etc/os-release VERSION_CODENAME is available on every modern systemd
  # host without requiring lsb-release; the previous `lsb_release -cs`
  # form 100'd the apt source on minimal Debian LXC templates that ship
  # without lsb-release. apt install gets -y to avoid interactive prompt
  # in non-TTY mitamae context.
  # Wrap in `bash -c` because mitamae's execute runs via /bin/sh, which is
  # dash on Ubuntu and rejects `set -o pipefail` (same fix already used by
  # cookbooks/codex-cli, cookbooks/mcp, cookbooks/herdr -- confirmed live:
  # the un-wrapped form fails with "set: Illegal option -o pipefail" and,
  # since mitamae has no ignore_failure, aborts the whole recipe run).
  command <<~SH.strip
    bash -c '
      set -euo pipefail
      wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      . /etc/os-release
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $VERSION_CODENAME main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
      sudo apt-get update && sudo apt-get install -y terraform
    '
  SH
  user node[:setup][:system_user]
  not_if { File.exist?("/usr/bin/terraform") || File.exist?("/usr/local/bin/terraform") }
end
