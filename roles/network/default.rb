# Network connectivity and VPN
include_platform_cookbook "tailscale"

# Network testing and monitoring tools
include_platform_cookbook "speedtest-cli"
include_cookbook "iperf3"

# Remote access and file transfer
include_platform_cookbook "mosh"
include_platform_cookbook "eternal-terminal"
include_cookbook "sshpass"
include_cookbook "osc52-clipboard"

unless node[:platform] == "darwin"
  include_cookbook "rclone"
end

# Network device management
include_cookbook "yamaha-network"
