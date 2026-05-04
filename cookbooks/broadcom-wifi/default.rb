# Broadcom WiFi STA driver. Only relevant on bare-metal hosts with a
# Broadcom wireless chipset; skip inside containers (LXC, docker) where
# the kernel module cannot be loaded and the package isn't even
# available in the trimmed apt sources.
container = run_command("systemd-detect-virt -c 2>/dev/null", error: false).stdout.strip
if container != "" && container != "none"
  MItamae.logger.info("broadcom-wifi: skipped (running inside #{container} container)")
  return
end

%w(bcmwl-kernel-source network-manager).each do |pkg|
  package pkg do
    action :install
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end
