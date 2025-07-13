# Network connectivity and VPN
include_cookbook "tailscale"

# Network testing and monitoring tools
include_cookbook "speedtest-cli"
include_cookbook "iperf3"

# Remote access and file transfer
include_cookbook "mosh"

unless node[:platform] == "darwin"
  include_cookbook "rclone"
end
