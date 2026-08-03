# frozen_string_literal: true
#
# gnupg, OS-independent half: the ~/.gnupg directory, the agent config, and the
# shell profile entry. Included LAST by darwin.rb and linux.rb, both of which
# install gnupg + their own pinentry flavour and set
# node[:gnupg][:pinentry_program] first -- the template below renders that
# value, and the pinentry binary has to exist before the agent reloads onto the
# new config.

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
#
# `source "templates/..."` resolves against THIS file's cookbook, so the
# template stays in cookbooks/gnupg/templates/ and both per-OS recipes reach it
# through this shared include rather than each naming it.
template "#{node[:setup][:home]}/.gnupg/gpg-agent.conf" do
  owner node[:setup][:user]
  group node[:setup][:group]
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

# Add GnuPG to profile. Defer `gpg-connect-agent updatestartuptty` until
# first gpg / git invocation. The eager call costs ~13ms per shell start;
# the typical shell never invokes gpg, so the cost was pure waste.
# GPG_TTY is exported eagerly so gpg-agent has a TTY hint when the
# lazy-loader fires.
add_profile "gnupg" do
  bash_content <<~'EOH'
    # GPG Agent configuration. Each wrapper self-unfunctions on first
    # invocation after pinging gpg-agent for a fresh TTY. The agent
    # call is inlined (no shared helper) because Claude Code's shell
    # snapshot drops single-underscore-prefixed functions, which broke
    # the earlier `_sh1_gpg_tty_sync` helper-based design with
    # `command not found: _sh1_gpg_tty_sync` on every git invocation.
    export GPG_TTY=$(tty)
    gpg() {
      unfunction gpg 2>/dev/null
      command gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
      command gpg "$@"
    }
    git() {
      unfunction git 2>/dev/null
      command gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
      command git "$@"
    }
  EOH
end
