# frozen_string_literal: true
#
# fzf, darwin half: the Homebrew formula, whose completion / key-binding
# scripts live under the brew opt prefix and need that prefix on PATH. The
# linux half sources the same two scripts from /usr/share/doc/fzf/examples and
# needs no PATH entry -- different shell wiring, hence the per-OS split.
include_cookbook "fzf::common"

package "fzf"

add_profile "fzf" do
  bash_content <<-EOM
if [[ ! "$PATH" == */opt/homebrew/opt/fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/opt/homebrew/opt/fzf/bin"
fi
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
# Defer completion + key-bindings — they post-prompt load via zsh-defer
# (registered by Sheldon at priority 20). First Ctrl-T / Ctrl-R may miss
# the binding by a few ms; fall through to eager source if zsh-defer is
# absent (non-zsh shells or sheldon not yet sourced).
if (( $+functions[zsh-defer] )); then
  zsh-defer source "/opt/homebrew/opt/fzf/shell/completion.zsh"
  zsh-defer source "/opt/homebrew/opt/fzf/shell/key-bindings.zsh"
else
  [[ $- == *i* ]] && source "/opt/homebrew/opt/fzf/shell/completion.zsh" 2> /dev/null
  source "/opt/homebrew/opt/fzf/shell/key-bindings.zsh"
fi
EOM

end
