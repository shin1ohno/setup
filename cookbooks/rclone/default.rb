remote_file "#{node[:setup][:root]}/rclone-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

if node[:platform] == "darwin"
  package "macfuse" do
    not_if "test -d /Library/Filesystems/macfuse.fs"
  end
  
  execute "installing rclone" do
    command <<-EOF
      cd #{node[:setup][:root]} && \
      git clone https://github.com/rclone/rclone.git && \
      cd rclone && \
      make GOTAGS=cmount
    EOF
    not_if "which rclone"
  end
else #linux
  execute "RCLONE_NO_UPDATE_PROFILE=1 #{node[:setup][:root]}/rclone-install.sh" do
    not_if "which rclone"
    user node[:setup][:system_user]
  end
end

