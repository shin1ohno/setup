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

  # Idempotent: re-runs after partial failures (e.g. a prior clone succeeded
  # but `make` failed) by fast-forwarding an existing clone instead of
  # re-cloning. `git clone` ENOENTs if the dir already exists; a separate
  # existence check routes to `git pull` in that case.
  execute "installing rclone" do
    command <<-EOF
      cd #{node[:setup][:root]} && \
      if [ -d rclone/.git ]; then
        cd rclone && git fetch --depth 1 origin master && git reset --hard origin/master
      else
        rm -rf rclone
        git clone --depth 1 https://github.com/rclone/rclone.git
        cd rclone
      fi && \
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

