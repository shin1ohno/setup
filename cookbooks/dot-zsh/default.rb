include_cookbook "typewritten"
include_cookbook "oh-my-zsh"

add_profile "dot-zsh" do
  priority 10
  bash_content <<"EOM"
export PATH=#{ENV['HOME']}/.local/bin:$PATH
export ARCHPREFERENCE=arm64
alias bri="envchain bricolage bundle exec bricolage"
autoload -U bashcompinit
bashcompinit
function select-history() {
  BUFFER=$(history -n -r 1 | fzf-tmux -d --reverse --no-sort +m --query "$LBUFFER" --prompt="History > ")
  CURSOR=$#BUFFER
}
zle -N select-history
EOM
end

add_profile "dot-zsh" do
  priority 60 #ensure to load after the oh-my-zsh
  bash_content <<"EOM"
bindkey '^r' select-history
EOM
end
