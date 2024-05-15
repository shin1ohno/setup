case node[:platform]
when "darwin"
  execute "brew tap teamookla/speedtest && brew update" do
    not_if "which speedtest"
  end
when "ubuntu" 
  directory "#{node[:setup][:root]}/speedtest-cli" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  remote_file "#{node[:setup][:root]}/speedtest-cli/script.deb.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/script.deb.sh"
  end

  execute "Install speedtest-cli" do
    command "#{node[:setup][:root]}/speedtest-cli/script.deb.sh"
    action :run
    not_if "which speedtest"
  end
end

package "speedtest-cli" do
  not_if "which speedtest"
end
