# frozen_string_literal: true

execute "$HOME/.volta/bin/npm install -g pm2" do
  not_if "which pm2"
  cwd ENV["HOME"]
end

c = "sudo env PATH=$PATH:#{ENV['HOME']}/.volta/bin #{ENV['HOME']}/.volta/tools/image/packages/pm2/lib/node_modules/pm2/bin/pm2 startup launchd -u $USER --hp #{ENV['HOME']}" 

if node[:platform] == "darwin"
  execute "setup pm2" do
    command c
    not_if "test -f ~/Library/LaunchAgents/pm2.$USER.plist"
  end
else
  execute "setup pm2" do
    cwd ENV["HOME"]
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
