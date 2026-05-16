# frozen_string_literal: true

# Phase 4 zsh-startup refactor: Sheldon + starship on all platforms.
# cookbooks/oh-my-zsh/ and cookbooks/typewritten/ are intentionally left
# on disk for ~1 week as a rollback safety net — revert by swapping these
# two includes back to typewritten + oh-my-zsh.
include_cookbook "starship"
include_cookbook "sheldon"

add_profile "dot-zsh" do
  priority 10
  bash_content <<"EOM"
# Defaults that /etc/zshrc used to set. We `unsetopt GLOBAL_RCS` in
# .zshenv to skip /etc/zshrc (saves ~10-20ms at startup), so replicate
# the few settings that matter for interactive use here.
HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history
HISTSIZE=2000
SAVEHIST=1000
setopt COMBINING_CHARS

export PATH=#{node[:setup][:root]}/bin:#{node[:setup][:home]}/.local/bin:$PATH
export ARCHPREFERENCE=arm64
alias bri="envchain bricolage bundle exec bricolage"

# compinit setup, initialized once so all later profile.d entries
# (sheldon, fzf-tab, fzf-advanced, mise, zoxide, ...) can register
# completions via `compdef` without triggering compinit a second time.
# Daily-cache: rebuild dump only if older than 24h, otherwise load cached
# dump with -C (skip security audit + skip regeneration check). -i
# ignores insecure-dir prompts when rebuilding.
# bashcompinit is intentionally NOT loaded here — it adds ~5ms but is
# only required by pm2 / awscli legacy `complete -F|-C` lines, which
# now live inside lazy-load wrappers (load bashcompinit themselves).
ZSH_COMPDUMP="${ZDOTDIR:-$HOME}/.zcompdump-${HOST}-${ZSH_VERSION}"
autoload -Uz compinit
if [[ -s $ZSH_COMPDUMP ]] && (( $(date +%s) - $(stat -f %m "$ZSH_COMPDUMP" 2>/dev/null || echo 0) < 86400 )); then
  compinit -C -d "$ZSH_COMPDUMP"
else
  compinit -i -d "$ZSH_COMPDUMP"
fi

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
