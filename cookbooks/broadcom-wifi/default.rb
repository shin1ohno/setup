%w(bcmwl-kernel-source network-manager).each do |pkg|
  package pkg do
    action :install
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end
