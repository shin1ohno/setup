# frozen_string_literal: true

# Phase 4 zsh-startup refactor: darwin migrated to Sheldon + starship.
# linux.rb still uses oh-my-zsh + typewritten until Phase 4 is extended
# to linux. Keep both cookbook trees on disk for ~1 week as a rollback
# safety net (revert by swapping the includes here).
if node[:platform] == "darwin"
  include_cookbook "starship"
  include_cookbook "sheldon"
else
  include_cookbook "typewritten"
  include_cookbook "oh-my-zsh"
end

add_profile "dot-zsh" do
  priority 10
  bash_content <<"EOM"
export PATH=#{node[:setup][:root]}/bin:#{node[:setup][:home]}/.local/bin:$PATH
export ARCHPREFERENCE=arm64
alias bri="envchain bricolage bundle exec bricolage"

# compinit + bashcompinit, initialized once so all later profile.d entries
# (sheldon, fzf-tab, fzf-advanced, mise, zoxide, ...) can register
# completions via `compdef` without triggering compinit a second time.
# Daily-cache pattern: rebuild dump only if older than 24h, otherwise
# load cached dump with -C (no security audit).
autoload -Uz compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi
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
  priority 60 # ensure to load after the oh-my-zsh
  bash_content <<"EOM"
bindkey '^r' select-history
EOM
end
