# Broadcom WiFi STA driver. Only relevant on bare-metal hosts with a
# Broadcom wireless chipset. Container scope is handled at the entry
# recipe level (linux.rb refuses to run inside any container) — no
# per-cookbook virt guard needed here.

%w(bcmwl-kernel-source network-manager).each do |pkg|
  package pkg do
    action :install
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end
