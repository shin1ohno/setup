# frozen_string_literal: true

git_clone "ohmyzsh" do
  uri "https://github.com/ohmyzsh/ohmyzsh.git"
  cwd node[:setup][:root]
end

plugin_dir = "#{node[:setup][:root]}/ohmyzsh/custom/plugins"

git_clone "zsh-autosuggestions" do
  uri "https://github.com/zsh-users/zsh-autosuggestions.git"
  cwd plugin_dir
end

git_clone "zsh-syntax-highlighting" do
  uri "https://github.com/zsh-users/zsh-syntax-highlighting.git"
  cwd plugin_dir
end

add_profile "ohmyzsh" do
  priority 20
  bash_content <<"EOM"
export ZSH="#{node[:setup][:root]}/ohmyzsh"
export UPDATE_ZSH_DAYS=1
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="true"
DISABLE_UNTRACKED_FILES_DIRTY="true"
plugins=(ruby vi-mode z zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh
export LANG=en_US.UTF-8
if [[ -n $SSH_CONNECTION ]]; then
 export EDITOR='vim'
else
 export EDITOR='nvim'
fi
# List directory files when changing directory
function chpwd() {
  emulate -L zsh
  tree -L 1
}
EOM
end
