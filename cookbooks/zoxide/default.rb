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
  bash_content <<-BASH
  eval "$(zoxide init zsh)"
  BASH
end

