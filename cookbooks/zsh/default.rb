# frozen_string_literal: true

install_package "zsh" do
  darwin "zsh"
  ubuntu "zsh"
end

zsh_path = case node[:platform]
           when "darwin"
             "#{node[:homebrew][:prefix]}/bin/zsh"
           when "ubuntu"
             "/usr/bin/zsh"
end

execute " sudo echo #{zsh_path} | sudo tee -a /etc/shells > /dev/null" do
  not_if "grep -q #{zsh_path} /etc/shells"
end

execute "sudo chsh -s #{zsh_path} #{node[:setup][:user]}" do
  # Read the user's login shell from /etc/passwd directly. `$SHELL` is
  # not always set in mitamae's child shell, and even when it is, it
  # reflects the parent shell's preference rather than the system record.
  not_if {
    next true unless zsh_path
    passwd_shell = run_command("getent passwd #{node[:setup][:user]} 2>/dev/null", error: false).stdout.split(":")[6].to_s.strip
    next true if passwd_shell == zsh_path
    # NSS-virtual users (GCE OS Login's libnss_oslogin, sssd, LDAP/NIS, etc.)
    # resolve fine through getent/PAM but have no LITERAL /etc/passwd line --
    # chsh edits that file directly (not via NSS) and always fails with
    # "user does not exist in /etc/passwd" for such accounts. mitamae has no
    # ignore_failure, so an unguarded failure here aborts the entire recipe
    # run, silently skipping every cookbook after this one (roles/programming,
    # roles/llm, etc.). Detect the mismatch and skip gracefully instead --
    # the `.bash_profile` hand-off below is what actually gets those accounts
    # onto zsh.
    run_command("grep -q \"^#{node[:setup][:user]}:\" /etc/passwd", error: false).exit_status != 0
  }
end

# Skipping the chsh above keeps the run alive but leaves the account on whatever
# login shell the directory hands out -- /bin/bash on GCE OS Login. There is no
# per-instance override for that: OS Login takes the shell from the account's
# POSIX attributes, and for a Google Workspace identity only a domain
# administrator can write them (`gcloud compute os-login remove-profile --help`
# states it outright, and the CLI exposes no subcommand that sets them). So hand
# off from bash to zsh at login instead of leaving such hosts on bash.
#
# ~/.bash_profile, NOT ~/.profile: bash reads .bash_profile in preference to
# .profile, which scopes the hand-off to bash alone and leaves the distro's
# .profile -- also read by sh and dash -- untouched. That precedence cuts both
# ways, so the fall-through path has to source .profile explicitly or a login
# bash loses what lives there (on Debian: ~/.bashrc, ~/bin, ~/.local/bin).
#
# Only LOGIN shells read this file, so `ssh host cmd`, scp, sftp and rsync are
# structurally unaffected -- none of them get a login shell. The tty tests are
# belt-and-braces on top of that, and they also route a piped `... | ssh host`
# to bash rather than exec'ing an interactive zsh onto a non-tty.
#
# SHELL is re-exported before the exec because sshd sets it from the passwd
# entry: without this, anything inside the zsh session that spawns "$SHELL"
# (tmux, vim :shell, git's own editor logic) would start bash again.
#
# `file` + `content` rather than the append-guarded `execute`s above: appending
# is not idempotent so those need a marker grep, whereas a whole-file write is,
# and mitamae diffs `content` natively -- so editing this block re-renders the
# file instead of being skipped by a stale marker. owner/group are deliberately
# omitted: mitamae runs as the target user, so the file is correctly owned on
# creation, and naming an owner would trigger a chown that fails on exactly the
# NSS-virtual accounts this block exists for (mitamae reads their group as the
# literal "UNKNOWN").
file "#{node[:setup][:home]}/.bash_profile" do
  mode "644"
  content <<~PROFILE
    # Managed by cookbooks/zsh -- edits here are overwritten on the next apply.
    #
    # This account resolves through NSS (GCE OS Login, sssd, LDAP/NIS) and has no
    # /etc/passwd line, so `chsh` cannot set its login shell and the directory
    # hands out /bin/bash. Hand off to zsh here instead.
    if [ -x '#{zsh_path}' ] && [ -z "$ZSH_VERSION" ] && [ -t 0 ] && [ -t 1 ]; then
      # sshd exports SHELL from the passwd entry, so tools that spawn "$SHELL"
      # would still start bash from inside the zsh session without this.
      SHELL='#{zsh_path}'
      export SHELL
      exec '#{zsh_path}' -l
    fi

    # Fall-through: zsh missing, or a non-interactive login shell. This file takes
    # precedence over ~/.profile, so source it to keep bash's normal startup.
    if [ -f "$HOME/.profile" ]; then
      . "$HOME/.profile"
    fi
  PROFILE
  only_if {
    next false unless zsh_path
    passwd_shell = run_command("getent passwd #{node[:setup][:user]} 2>/dev/null", error: false).stdout.split(":")[6].to_s.strip
    next false if passwd_shell == zsh_path
    run_command("grep -q \"^#{node[:setup][:user]}:\" /etc/passwd", error: false).exit_status != 0
  }
end

execute "touch #{node[:setup][:home]}/.zshrc" do
  not_if { File.exist?("#{node[:setup][:home]}/.zshrc") }
end

# Match any form of the profile source line: tilde (`. ~/.setup_shin1ohno/profile`),
# absolute (`. /Users/.../.setup_shin1ohno/profile`), or `$HOME`-prefixed. The prior
# absolute-only check missed legacy tilde-form lines and re-appended a duplicate
# absolute-form line on every apply, doubling shell startup time.
execute "echo '. #{node[:setup][:root]}/profile' >> ~/.zshrc" do
  not_if "fgrep -q 'setup_shin1ohno/profile' ~/.zshrc"
end

# Disable system-wide rc files via `unsetopt GLOBAL_RCS` in ~/.zshenv.
# Saves ~10-20ms of shell startup by skipping /etc/zprofile, /etc/zshrc,
# /etc/zlogin (which mostly set HISTFILE/SIZE and a few terminfo keymaps).
# Those defaults are replicated in profile.d/10-dot-zsh.sh.
#
# Must live in .zshenv because .zshrc runs AFTER /etc/zshrc — too late.
# /etc/zshenv has already run by .zshenv time (acceptable; it's nearly
# always empty on macOS).
execute "touch #{node[:setup][:home]}/.zshenv" do
  not_if { File.exist?("#{node[:setup][:home]}/.zshenv") }
end

execute "echo 'unsetopt GLOBAL_RCS' >> #{node[:setup][:home]}/.zshenv" do
  not_if "fgrep -q 'unsetopt GLOBAL_RCS' #{node[:setup][:home]}/.zshenv"
end

# GITHUB_TOKEN from the gh CLI's stored credential, so every tool that hits the
# GitHub API authenticated gets the 5000 req/h limit instead of the 60 req/h
# unauthenticated one. The original pain was `mise up` exhausting 60 req/h
# (resolving releases via the github/ubi/aqua backends) and then 403-ing, but the
# var is general: gh itself, ubi/aqua installs, and any gh-API script benefit too.
# Derived from `gh auth token` so the right account is picked per machine
# (personal vs corp) with no static PAT to store on disk.
add_profile "github-token" do
  bash_content <<~'EOS'
    # Only set when unset (respects an explicit token / CI) and only when gh is
    # present AND yields a token — never export an empty value (a blank
    # Authorization header is worse than sending none). Interactive only: profile
    # is sourced from ~/.zshrc, so non-interactive shells pay no `gh` cost.
    if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
      _sh1_gh_token="$(gh auth token 2>/dev/null)"
      [ -n "${_sh1_gh_token}" ] && export GITHUB_TOKEN="${_sh1_gh_token}"
      unset _sh1_gh_token
    fi
  EOS
end
