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
# Daily-cache: rebuild dump only if older than 24h, otherwise load cached
# dump with -C (skip security audit + skip regeneration check). -i
# ignores insecure-dir prompts when rebuilding.
# Dump file is host+version-qualified to match the existing convention
# (formerly produced by OMZ via ZSH_COMPDUMP).
# stat is used instead of zsh glob qualifiers because the glob form
# `(#qN.mh+24)` requires extendedglob, which OMZ used to enable for us.
ZSH_COMPDUMP="${ZDOTDIR:-$HOME}/.zcompdump-${HOST}-${ZSH_VERSION}"
autoload -Uz compinit
if [[ -s $ZSH_COMPDUMP ]] && (( $(date +%s) - $(stat -f %m "$ZSH_COMPDUMP" 2>/dev/null || echo 0) < 86400 )); then
  compinit -C -d "$ZSH_COMPDUMP"
else
  compinit -i -d "$ZSH_COMPDUMP"
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
