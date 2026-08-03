# frozen_string_literal: true
#
# ssh (macOS): SSH agent management is handled by either the launchd-managed
# system ssh-agent (default macOS) or per-user `IdentityAgent` directives
# in ~/.ssh/config (Mercari Macs route to a secured container socket via
# that mechanism). In both cases, sourcing `eval "$(ssh-agent)"` per shell
# creates an orphan agent that nothing uses and costs 100-300ms at every
# shell start.
#
# So this side does not merely skip the fragment linux.rb writes — it deletes
# it, to clean up hosts that applied a revision predating that split in
# behaviour. No common.rb: the two sides share no resources at all.

# Remove the stale eval line from prior installs.
file "#{node[:setup][:root]}/profile.d/10-ssh.sh" do
  action :delete
end
