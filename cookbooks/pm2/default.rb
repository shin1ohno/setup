# frozen_string_literal: true

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

mise_tool "pm2" do
  backend "npm"
end

c = "sudo env PATH=$PATH:#{node[:setup][:home]}/.local/share/mise/shims #{node[:setup][:home]}/.local/share/mise/shims/pm2 startup launchd -u $USER --hp #{node[:setup][:home]}"

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
  bash_content <<"EOM"
COMP_WORDBREAKS=${COMP_WORDBREAKS/=/}
COMP_WORDBREAKS=${COMP_WORDBREAKS/@/}
export COMP_WORDBREAKS

if type complete &>/dev/null; then
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
elif type compctl &>/dev/null; then
  _pm2_completion () {
    local cword line point words si
    read -Ac words
    read -cn cword
    let cword-=1
    read -l line
    read -ln point
    si="$IFS"
    IFS=$'\n' reply=($(COMP_CWORD="$cword" \
                       COMP_LINE="$line" \
                       COMP_POINT="$point" \
                       pm2 completion -- "${words[@]}" \
                       2>/dev/null)) || return $?
    IFS="$si"
  }
  compctl -K _pm2_completion + -f + pm2
fi
EOM
end
