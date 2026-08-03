# frozen_string_literal: true
#
# fzf, linux half: the distro package, whose completion / key-binding scripts
# ship under /usr/share/doc/fzf/examples and are sourced directly -- no PATH
# entry and no zsh-defer wiring, unlike the Homebrew layout the darwin half
# has to work around. Different shell wiring, hence the per-OS split.
include_cookbook "fzf::common"

install_package "fzf" do
  ubuntu "fzf"
end

add_profile "fzf" do
  bash_content <<-EOM
[[ $- == *i* ]] && source "/usr/share/doc/fzf/examples/key-bindings.zsh" 2> /dev/null
[[ $- == *i* ]] && source "/usr/share/doc/fzf/examples/completion.zsh" 2> /dev/null
export FZF_COMPLETION_TRIGGER='--'
export FZF_DEFAULT_COMMAND='fd --type file'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_DEFAULT_OPTS=$FZF_DEFAULT_OPTS"
--height=40% 
--layout=reverse 
--info=inline 
--border 
--margin=1 
--padding=1
--prompt 'All> '
--header 'CTRL-D: Directories / CTRL-F: Files'
--bind 'ctrl-d:change-prompt(Directories> )+reload(find * -type d)'
--bind 'ctrl-f:change-prompt(Files> )+reload(find * -type f)'
--color=bg+:#3B4252,bg:#2E3440,spinner:#81A1C1,hl:#616E88,fg:#D8DEE9,header:#616E88,info:#81A1C1,pointer:#81A1C1,marker:#81A1C1,fg+:#D8DEE9,prompt:#81A1C1,hl+:#81A1C1
"
EOM
end
