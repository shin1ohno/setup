# frozen_string_literal: true

include_recipe "cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    root: "#{ENV['HOME']}/.setup_shin1ohno",
    user: user,
    group: group,
  }
)

include_role "base"
include_cookbook "bluez"
include_cookbook "zeroconf"
include_cookbook "broadcom-wifi"
include_cookbook "roon-server"
include_cookbook "docker-engine"
include_cookbook "samba"
include_cookbook "smartmontools"
include_cookbook "tailscale"
include_cookbook "ansible"
