# frozen_string_literal: true

# pip rather than a distro package: neither the Ubuntu archive nor the Debian
# one carries speedtest-cli, and the Ookla tarball this cookbook uses on darwin
# is a separate (non-free) CLI. pyenv is provisioned by roles/programming, which
# every linux entry recipe includes ahead of roles/network.
execute "Install speedtest-cli" do
  command "$HOME/.pyenv/shims/pip install speedtest-cli"
  not_if "test -x $HOME/.pyenv/shims/pip && $HOME/.pyenv/shims/pip list | grep -q speedtest-cli"
end
