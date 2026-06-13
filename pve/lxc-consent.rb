# frozen_string_literal: true
#
# Entry recipe for the consent LXC (CT 110): Hydra consent app — Google
# OAuth login + DCR proxy + consent UI rendering. Tightly coupled to
# hydra LXC (admin API on node[:hydra_server][:lan_host]:4445, default
# hydra.home.local:4445) but isolated for per-service ZFS rollback
# granularity.
#
# RAM 0.5 GiB / CPU 1.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-consent.rb
#
# Service logic lives in cookbooks/lxc-consent (Phase 4 extraction). This entry
# stays thin: include the cookbook, then the lxc-core + elastic-agent tail.

include_recipe "../cookbooks/functions/default"

include_cookbook "lxc-consent"
lxc_entry(tags: ["lxc", "consent"])
