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
    mode "755"
  end

  execute "setup pm2" do
    command c
    not_if "test -f ~/Library/LaunchAgents/pm2.$USER.plist"
  end
else
  execute "setup pm2" do
    cwd node[:setup][:home]
    command c
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
