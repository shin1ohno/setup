# frozen_string_literal: true

install_package "gnupg" do
  darwin "gnupg"
  ubuntu "gnupg"
end

# Pinentry binary path — set before the template renders.
# - macOS: pinentry-mac (Homebrew) gives a native dialog; fall back to
#   pinentry-tty for headless ssh sessions.
# - Linux: pinentry-curses ships with the pinentry-curses apt package.
node.reverse_merge!(
  gnupg: {
    pinentry_program: case node[:platform]
                      when "darwin"
                        "/opt/homebrew/bin/pinentry-tty"
                      else
                        "/usr/bin/pinentry-curses"
                      end,
  }
)

# Linux: pinentry-curses must be installed before the agent reloads, or
# gpg-agent fails to launch pinentry on the first commit after the
# config change.
if node[:platform] != "darwin"
  package "pinentry-curses" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' pinentry-curses 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end

# Create .gnupg directory with proper permissions
execute "mkdir -p #{node[:setup][:home]}/.gnupg" do
  not_if { Dir.exist?("#{node[:setup][:home]}/.gnupg") }
end

execute "chmod 700 #{node[:setup][:home]}/.gnupg" do
  only_if { Dir.exist?("#{node[:setup][:home]}/.gnupg") }
  # Skip when the directory is already 0700 — `execute "chmod 700"` is
  # otherwise a no-op call every run.
  not_if {
    File.exist?("#{node[:setup][:home]}/.gnupg") &&
      run_command("stat -c %a #{node[:setup][:home]}/.gnupg", error: false).stdout.strip == "700"
  }
end

# gpg-agent.conf — deployed on both platforms with the platform-specific
# pinentry path. Cache TTLs are unified at 1 month (2592000s) so commit
# signing in the Claude Code Bash sandbox does not re-prompt for the
# passphrase across long sessions.
#
# Drop the old `not_if File.exist?` guard that previously locked the
# config to first-run — that prevented future TTL bumps and pinentry
# changes from taking effect on existing hosts. mitamae's template
# resource is content-hash idempotent on its own.
template "#{node[:setup][:home]}/.gnupg/gpg-agent.conf" do
  owner node[:setup][:user]
  mode "600"
  source "templates/gpg-agent.conf"
  notifies :run, "execute[reload gpg-agent]"
end

# Apply the new gpg-agent.conf to the running agent. Without this, the
# stale agent process keeps the pre-update TTLs until the user logs out
# / restarts the agent manually.
execute "reload gpg-agent" do
  command "gpg-connect-agent reloadagent /bye"
  user node[:setup][:user]
  action :nothing
end

# macOS still needs the curses fallback bundled by the `pinentry`
# Homebrew formula (it ships pinentry-tty + pinentry-curses).
if node[:platform] == "darwin"
  package "pinentry"
end

# Add GnuPG to profile
add_profile "gnupg" do
  bash_content <<~EOH
    # GPG Agent configuration
    export GPG_TTY=$(tty)
    # Refresh gpg-agent tty in case user switches into an X session
    gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
  EOH
end
