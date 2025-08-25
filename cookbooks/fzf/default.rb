# frozen_string_literal: true

git_clone "fzf-git.sh" do
  cwd node[:setup][:root]
  uri "git@github.com:junegunn/fzf-git.sh.git"
end

execute "git pull" do
  cwd "#{node[:setup][:root]}/fzf-git.sh"
end

case node[:platform]
when "darwin"
package "fzf"

add_profile "fzf" do
  bash_content <<-EOM
if [[ ! "$PATH" == */opt/homebrew/opt/fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/opt/homebrew/opt/fzf/bin"
fi
[[ $- == *i* ]] && source "/opt/homebrew/opt/fzf/shell/completion.zsh" 2> /dev/null
source "/opt/homebrew/opt/fzf/shell/key-bindings.zsh"
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

when "ubuntu"
  package "fzf" do
    user node[:setup][:user]
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
end

add_profile "fzf-advanced" do
  bash_content <<~'EOS'
  # https://github.com/junegunn/fzf/wiki/Examples
  tm() {
    [[ -n "$TMUX" ]] && change="switch-client" || change="attach-session"
    if [ $1 ]; then
      tmux $change -t "$1" 2>/dev/null || (tmux new-session -d -s $1 && tmux $change -t "$1"); return
    fi
    session=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | fzf --exit-0) &&  tmux $change -t "$session" || tmux
  }
  EOS
end

add_profile "fzf-git" do
  bash_content <<~EOS
    source "#{node[:setup][:root]}/fzf-git.sh/fzf-git.sh"
  EOS
end

