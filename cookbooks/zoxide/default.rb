remote_file "#{node[:setup][:root]}/zoxide-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

# Hit ENTER automatically when asked to install CLI tools.
# HAVE_SUDO_ACCESS=0 is required to skip `sudo` capability check.
execute "echo | env #{node[:setup][:root]}/zoxide-install.sh" do
  not_if "which zoxide"
end

add_profile "zoxide" do
  bash_content <<~'BASH'
    # Cache `zoxide init zsh` output; regenerate when binary changes.
    # ~10ms subprocess spawn → ~1ms source.
    _sh1_zoxide_bin=$(command -v zoxide)
    if [ -n "$_sh1_zoxide_bin" ]; then
      _sh1_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
      [ -d "$_sh1_cache_dir" ] || mkdir -p "$_sh1_cache_dir"
      _sh1_zoxide_cache="${_sh1_cache_dir}/zoxide-init.zsh"
      if [ ! -s "$_sh1_zoxide_cache" ] || [ "$_sh1_zoxide_cache" -ot "$_sh1_zoxide_bin" ]; then
        "$_sh1_zoxide_bin" init zsh > "$_sh1_zoxide_cache"
      fi
      . "$_sh1_zoxide_cache"
      unset _sh1_cache_dir _sh1_zoxide_cache
    fi
    unset _sh1_zoxide_bin
  BASH
end

