# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/mise-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "sh #{node[:setup][:root]}/mise-install.sh" do
  not_if "which mise"
end

# Make mise + its shims visible to subsequent cookbooks in the same mitamae
# run (e.g. nodejs, pm2, codex-cli all expect mise shims on PATH). Without
# this, `add_profile` only takes effect for new login shells, not for the
# rest of this run.
prepend_path(
  "#{node[:setup][:home]}/.local/bin",
  "#{node[:setup][:home]}/.local/share/mise/shims",
)

execute "mise self-update" do
  command "$HOME/.local/bin/mise self-update -y --no-plugins || echo '[setup] WARNING: mise self-update failed, continuing with current version'"
  only_if { File.exist? "#{node[:setup][:home]}/.local/bin/mise" }
end

# Install usage tool for mise completions
execute "$HOME/.local/bin/mise use -g usage" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list usage | grep -q 'usage'"
end

# Generate shell completions
directory "#{node[:setup][:home]}/.local/share/bash-completion/completions" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "$HOME/.local/bin/mise completion bash --include-bash-completion-lib > #{node[:setup][:home]}/.local/share/bash-completion/completions/mise" do
  user node[:setup][:user]
  not_if "test -f #{node[:setup][:home]}/.local/share/bash-completion/completions/mise"
end

# Create zsh completions directory if it doesn't exist
directory "#{node[:setup][:home]}/.local/share/zsh/site-functions" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "$HOME/.local/bin/mise completion zsh > #{node[:setup][:home]}/.local/share/zsh/site-functions/_mise" do
  user node[:setup][:user]
  not_if "test -f #{node[:setup][:home]}/.local/share/zsh/site-functions/_mise"
end

directory "#{node[:setup][:home]}/.config/fish/completions" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  only_if "which fish"
end

execute "$HOME/.local/bin/mise completion fish > #{node[:setup][:home]}/.config/fish/completions/mise.fish" do
  user node[:setup][:user]
  not_if "test -f #{node[:setup][:home]}/.config/fish/completions/mise.fish"
  only_if "which fish"
end

add_profile "mise" do
  bash_content <<~'EOS'
    # mise-en-place tool version manager.
    # --shims mode + per-shell cache: caches the `mise activate --shims`
    # output and only regenerates when the mise binary itself changes.
    # `mise activate --shims` is ~110ms unsalted because it parses config
    # + emits a shim PATH export each shell. Caching cuts that to ~1ms.
    # Trade-off: `[env]` sections and `[hooks]` in mise.toml do not apply
    # with shims. Switch back to bare `mise activate` if those are needed.
    if [ -f "$HOME/.local/bin/mise" ]; then
      _sh1_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
      [ -d "$_sh1_cache_dir" ] || mkdir -p "$_sh1_cache_dir"
      _sh1_mise_bin="$HOME/.local/bin/mise"
      if [ -n "$BASH_VERSION" ]; then
        _sh1_mise_cache="${_sh1_cache_dir}/mise-activate.bash"
        _sh1_mise_shell=bash
      elif [ -n "$ZSH_VERSION" ]; then
        _sh1_mise_cache="${_sh1_cache_dir}/mise-activate.zsh"
        _sh1_mise_shell=zsh
      fi
      if [ -n "${_sh1_mise_shell:-}" ]; then
        if [ ! -s "$_sh1_mise_cache" ] || [ "$_sh1_mise_cache" -ot "$_sh1_mise_bin" ]; then
          "$_sh1_mise_bin" activate "$_sh1_mise_shell" --shims > "$_sh1_mise_cache"
        fi
        . "$_sh1_mise_cache"
      fi
      unset _sh1_cache_dir _sh1_mise_bin _sh1_mise_cache _sh1_mise_shell
    fi
  EOS
  fish_content <<~FISH
    # mise-en-place tool version manager (shims mode; see bash_content note)
    if test -f "$HOME/.local/bin/mise"
      eval ($HOME/.local/bin/mise activate fish --shims)
    end
  FISH
end

# Trust mise.toml in known setup-repo locations. mise refuses to auto-load
# untrusted configs (security posture); pre-trust the cookbook-managed
# setup repo so `cd <setup>` followed by mise-managed tool invocations
# work without an interactive prompt that mitamae has no way to satisfy.
#
# Defaults cover the two clone paths used during PVE rebuild:
#   - {home}/setup/mise.toml           (root@LXC bootstrap, e.g. /root/setup/)
#   - {home}/ManagedProjects/setup/mise.toml (shin1ohno user workspace)
#
# Override per host via node[:mise][:trust_paths] = [...] when the setup
# repo lives elsewhere.

default_trust_paths = [
  "#{node[:setup][:home]}/setup/mise.toml",
  "#{node[:setup][:home]}/ManagedProjects/setup/mise.toml",
]
trust_paths = node.dig(:mise, :trust_paths) || default_trust_paths

trust_paths.each do |path|
  execute "mise trust #{path}" do
    command "$HOME/.local/bin/mise trust '#{path}'"
    user node[:setup][:user]
    only_if "test -f '#{path}'"
    not_if "$HOME/.local/bin/mise trust --show 2>&1 | grep -qF '#{path}'"
  end
end
