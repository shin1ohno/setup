# frozen_string_literal: true
#
# Entry recipe for the samba LXC (CT 101): SMB share for [Media] read-only.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-samba.rb

include_recipe "../cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

include_cookbook "samba-server"
include_role "lxc-core"

node.reverse_merge!(elastic_agent: { tags: ["lxc", "samba"] })
include_cookbook "elastic-agent"
