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

# Remove stale profile entries from the prior OMZ + typewritten setup.
# Both used the same `add_profile` priority slots; without deletion they
# would source alongside the new sheldon profile and revive the slow path.
%w(20-ohmyzsh.sh 50-typewritten.sh).each do |stale|
  file "#{node[:setup][:root]}/profile.d/#{stale}" do
    action :delete
  end
end

add_profile "sheldon" do
  priority 20
  bash_content <<~EOM
    # Sheldon plugin manager + starship prompt + minimal vi keybinds.
    # Replaces OMZ + typewritten (priority 20 slot). compinit is set up
    # by cookbooks/dot-zsh priority 10 — do not re-init here.
    export PATH="#{node[:setup][:root]}/bin:$PATH"

    ZSH_AUTOSUGGEST_MANUAL_REBIND=1
    eval "$(sheldon source)"

    # vi mode (inline 4-line replacement for OMZ vi-mode plugin)
    bindkey -v
    export KEYTIMEOUT=1
    bindkey -M viins '^A' beginning-of-line
    bindkey -M viins '^E' end-of-line

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

    eval "$(starship init zsh)"
  EOM
end
