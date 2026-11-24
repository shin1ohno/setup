# frozen_string_literal: true

# Phase 4 zsh-startup refactor: Sheldon + starship on all platforms.
include_platform_cookbook "starship"
include_cookbook "sheldon"

# The /usr/sbin and /sbin entries of /etc/paths, which /etc/zprofile's
# path_helper would add. Terminal.app starts the shell through login(1), which
# hands it PATH=/usr/bin:/bin, and `unsetopt GLOBAL_RCS` (cookbooks/zsh) skips
# /etc/zprofile, so without this every interactive shell lacks sysctl,
# systemsetup, networksetup and diskutil, and a mitamae started from it aborts
# in cookbooks/host-profile. Appended (never prepended) and guarded, so
# Homebrew and user-local dirs keep their precedence and re-sourcing is a
# no-op. darwin-only: Linux shells already get these from their login PATH.
sbin_path = platform_value(
  darwin: <<~SH,
    case ":$PATH:" in *:/usr/sbin:*) ;; *) PATH="$PATH:/usr/sbin" ;; esac
    case ":$PATH:" in *:/sbin:*) ;; *) PATH="$PATH:/sbin" ;; esac
  SH
  linux: "",
)

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

#{sbin_path}export PATH=#{node[:setup][:root]}/bin:#{node[:setup][:home]}/.local/bin:$PATH
export ARCHPREFERENCE=arm64
alias bri="envchain bricolage bundle exec bricolage"

# User-space completion functions (_mise, _fractal, _wiki, ... — generated
# by cookbooks into ~/.local/share/zsh/site-functions) must be on fpath
# BEFORE compinit builds the dump, or they are never autoloaded.
fpath=("$HOME/.local/share/zsh/site-functions" $fpath)

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
# Use zsh's zstat builtin (no fork, portable across macOS/Linux).
# BSD `stat -f %m` and GNU `stat -c %Y` differ; zstat sidesteps both.
zmodload -F zsh/stat b:zstat 2>/dev/null
if [[ -s $ZSH_COMPDUMP ]] && (( $(date +%s) - $(zstat +mtime "$ZSH_COMPDUMP" 2>/dev/null || echo 0) < 86400 )); then
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
  priority 60 # load after the priority-10 block that defines select-history
  bash_content <<"EOM"
bindkey '^r' select-history
EOM
end
