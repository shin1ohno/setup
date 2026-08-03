remote_file "#{node[:setup][:root]}/rclone-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

# Linux-only (cookbooks/rclone/platform). The darwin arm this cookbook used to
# carry — macfuse plus a from-source `make GOTAGS=cmount` build — was
# unreachable: roles/network includes rclone only on the non-darwin branch, and
# its other caller (obsidian_file_sync) is itself linux-only. It is recoverable
# from git history if a Mac ever needs it.

# The rclone install.sh extracts a release zip and aborts with
# "None of the supported tools for extracting zip archives (unzip 7z
# busybox) were found" on minimal Debian 13 LXCs that lack unzip.
package "unzip" do
  user node[:setup][:system_user]
  not_if { run_command("dpkg-query -W -f='${Status}' unzip 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
end

execute "RCLONE_NO_UPDATE_PROFILE=1 #{node[:setup][:root]}/rclone-install.sh" do
  not_if "which rclone"
  user node[:setup][:system_user]
end

