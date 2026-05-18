# frozen_string_literal: true

# Sheldon: declarative TOML-driven zsh plugin manager (Rust). Replaces the
# Oh-My-Zsh framework. Activates the starship prompt at the end of its
# profile entry so prompt + plugins share one place.
#
# Cross-platform: the rossmacarthur crate.sh installer detects darwin /
# linux / arm64 / x86_64 automatically.

sheldon_bin = "#{node[:setup][:root]}/bin/sheldon"
sheldon_config_dir = "#{node[:setup][:home]}/.config/sheldon"

directory "#{node[:setup][:root]}/bin" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

directory "#{node[:setup][:home]}/.config" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

directory sheldon_config_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "install sheldon" do
  command <<~SH.strip
    curl --proto '=https' -fLsS https://rossmacarthur.github.io/install/crate.sh \
      | bash -s -- --repo rossmacarthur/sheldon --to "#{node[:setup][:root]}/bin"
  SH
  not_if "test -f #{sheldon_bin}"
end

template "#{sheldon_config_dir}/plugins.toml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

# Remove stale profile entries from previous installs. None of these are
# produced by any current cookbook — they're orphaned files from earlier
# tooling that profile.d still sources on every shell start. Cleaning
# them up here keeps the cookbook-managed profile.d / sheldon-driven path
# the sole source of plugin + prompt + jump-cd behavior.
#
#   20-ohmyzsh.sh                       — replaced by 20-sheldon.sh
#   50-typewritten.sh                   — replaced by starship init in 20-sheldon.sh
#   50-autojump.sh                      — orphan from autojump install; zoxide
#                                         covers the same intent
#   50-claude-code-spec-workflow.sh     — orphan profile entry; no cookbook
#                                         currently writes it
%w(20-ohmyzsh.sh 50-typewritten.sh 50-autojump.sh 50-claude-code-spec-workflow.sh).each do |stale|
  file "#{node[:setup][:root]}/profile.d/#{stale}" do
    action :delete
  end
end

add_profile "sheldon" do
  priority 20
  bash_content <<~'EOM'
    # Sheldon plugin manager + starship prompt + minimal vi keybinds.
    # Replaces OMZ + typewritten (priority 20 slot). compinit is set up
    # by cookbooks/dot-zsh priority 10 — do not re-init here.
    export PATH="$HOME/.setup_shin1ohno/bin:$PATH"

    # Cache `sheldon source` and `starship init zsh` outputs so the
    # subprocess spawn (sheldon ~30ms + starship ~20ms) only fires when
    # the underlying binary or sheldon config file changes. Regenerate
    # logic uses zsh's -ot ("older than") test against the binary /
    # config mtime.
    _sh1_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
    [[ -d $_sh1_cache_dir ]] || mkdir -p $_sh1_cache_dir

    _sh1_sheldon_cache="${_sh1_cache_dir}/sheldon-source.zsh"
    _sh1_sheldon_bin="$HOME/.setup_shin1ohno/bin/sheldon"
    _sh1_sheldon_cfg="$HOME/.config/sheldon/plugins.toml"
    # Regenerate via tmpfile + atomic mv so a sheldon failure (libgit2
    # auth hang, network outage, plugin clone error) cannot leave an
    # empty cache or block shell startup. On failure the previous cache
    # is preserved and the shell continues without plugins.
    if [[ ! -s $_sh1_sheldon_cache \
       || $_sh1_sheldon_cache -ot $_sh1_sheldon_bin \
       || $_sh1_sheldon_cache -ot $_sh1_sheldon_cfg ]]; then
      _sh1_sheldon_tmp="${_sh1_sheldon_cache}.tmp.$$"
      if "$_sh1_sheldon_bin" source > "$_sh1_sheldon_tmp" 2>/dev/null \
         && [[ -s $_sh1_sheldon_tmp ]]; then
        mv "$_sh1_sheldon_tmp" "$_sh1_sheldon_cache"
      else
        rm -f "$_sh1_sheldon_tmp"
      fi
      unset _sh1_sheldon_tmp
    fi
    ZSH_AUTOSUGGEST_MANUAL_REBIND=1
    [[ -s $_sh1_sheldon_cache ]] && source "$_sh1_sheldon_cache"

    # vi mode (inline replacement for OMZ vi-mode plugin) + emacs-style
    # cursor / history motion in insert mode (^A ^E ^B ^F ^P ^N).
    bindkey -v
    export KEYTIMEOUT=1
    bindkey -M viins '^A' beginning-of-line
    bindkey -M viins '^E' end-of-line
    bindkey -M viins '^B' backward-char
    bindkey -M viins '^F' forward-char
    bindkey -M viins '^P' up-line-or-history
    bindkey -M viins '^N' down-line-or-history

    # Locale + SSH-aware editor (preserved from prior OMZ profile)
    export LANG=en_US.UTF-8
    if [[ -n $SSH_CONNECTION ]]; then
      export EDITOR='vim'
    else
      export EDITOR='nvim'
    fi

    # tree-on-cd (preserved chpwd from prior OMZ profile)
    function chpwd() {
      emulate -L zsh
      tree -La 1
    }

    _sh1_starship_cache="${_sh1_cache_dir}/starship-init.zsh"
    _sh1_starship_bin=$(command -v starship)
    if [[ -n $_sh1_starship_bin ]] && [[ ! -s $_sh1_starship_cache \
       || $_sh1_starship_cache -ot $_sh1_starship_bin ]]; then
      "$_sh1_starship_bin" init zsh --print-full-init > "$_sh1_starship_cache"
    fi
    [[ -s $_sh1_starship_cache ]] && source "$_sh1_starship_cache"

    unset _sh1_cache_dir _sh1_sheldon_cache _sh1_sheldon_bin _sh1_sheldon_cfg _sh1_starship_cache _sh1_starship_bin
  EOM
end
