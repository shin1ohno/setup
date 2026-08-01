# frozen_string_literal: true

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

mise_tool "pm2" do
  backend "npm"
end

init_system = node[:platform] == "darwin" ? "launchd" : "systemd"
c = "sudo env PATH=$PATH:#{node[:setup][:home]}/.local/share/mise/shims #{node[:setup][:home]}/.local/share/mise/shims/pm2 startup #{init_system} -u $USER --hp #{node[:setup][:home]}"

if node[:platform] == "darwin"
  # Pre-create ~/Library/LaunchAgents. pm2 6.0.14's `startup launchd` tries
  # to open the plist for writing before running its own `mkdir -p` step,
  # which ENOENT-fails on fresh Macs where the directory doesn't yet exist.
  directory "#{node[:setup][:home]}/Library/LaunchAgents" do
    owner node[:setup][:user]
group node[:setup][:group]
    mode "755"
  end

  execute "setup pm2" do
    command c
    not_if "test -f ~/Library/LaunchAgents/pm2.$USER.plist"
  end
else
  # `pm2 startup systemd` shells out through mise's shim, and that
  # specific subcommand intermittently fails with "pm2 is not a valid
  # shim" (mise src/shims.rs err_no_version_set -- a tool-metadata
  # resolution issue elsewhere in the toolset, not actually about pm2)
  # even though `pm2 --version` and other invocations of the SAME shim
  # succeed immediately before and after. Confirmed live: `mise reshim`
  # right before this step does not reliably prevent it. mitamae has no
  # ignore_failure, so tolerate this non-fatally (systemd auto-start for
  # pm2 is a nice-to-have, not something later cookbooks depend on) --
  # log a WARN so it's visible rather than silently missing.
  execute "setup pm2" do
    cwd node[:setup][:home]
    command "#{c} || echo 'pm2: startup systemd setup failed (see cookbooks/pm2/default.rb) -- pm2 will not auto-start on boot; continuing' >&2"
    not_if "systemctl list-unit-files | grep pm2-$USER.service | grep enabled"
  end
end

add_profile "pm2" do
  bash_content <<~'EOM'
    # Lazy-load pm2 completion. The eager setup (bash-style `complete -F`)
    # adds ~3-5ms per shell and only matters when pm2 is tab-completed.
    # The wrapper unfunctions itself after registering completion + bash
    # compatibility shim.
    pm2() {
      unfunction pm2
      COMP_WORDBREAKS=${COMP_WORDBREAKS/=/}
      COMP_WORDBREAKS=${COMP_WORDBREAKS/@/}
      export COMP_WORDBREAKS
      autoload -U bashcompinit && bashcompinit
      _pm2_completion () {
        local si="$IFS"
        IFS=$'\n' COMPREPLY=($(COMP_CWORD="$COMP_CWORD" \
                               COMP_LINE="$COMP_LINE" \
                               COMP_POINT="$COMP_POINT" \
                               pm2 completion -- "${COMP_WORDS[@]}" \
                               2>/dev/null)) || return $?
        IFS="$si"
      }
      complete -o default -F _pm2_completion pm2
      command pm2 "$@"
    }
  EOM
end
