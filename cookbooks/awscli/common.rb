# frozen_string_literal: true
#
# awscli: the OS-independent half — the staging directory both installers
# download into, and the PATH prepend both need. Included FIRST by darwin.rb
# and linux.rb, so the directory exists before either download writes into it.

directory "#{node[:setup][:root]}/awscli" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Add /usr/local/bin to mitamae's in-process PATH so subsequent cookbooks'
# `run_command` calls (compile-time auth probes in require_external_auth, SSM
# fetch helpers) can find `aws`. Both installers land the binary there — the
# Linux one at /usr/local/aws-cli/v2/current/bin/aws with a /usr/local/bin/aws
# symlink, the AWSCLIV2.pkg one directly — but on Debian/Ubuntu LXCs running
# mitamae from a non-login bash (auto-mitamae SSH ForceCommand, `pct exec ...
# bash -c`) the default PATH is /sbin:/bin:/usr/sbin:/usr/bin and does NOT
# include /usr/local/bin. Without this prepend, every SSM-gated cookbook's
# auth probe returns exit 127 (command not found), and in non-TTY contexts
# require_external_auth silently skips the gated block — masquerading as
# "auth not configured" when the actual cause is missing $PATH. See
# ~/ManagedProjects/setup/.claude/rules/ruby.md "sudo secure_path strips user home" for the
# analogous pattern with user-installed shims.
#
# Pre-split this call sat at the END of each platform arm; here it runs at the
# TOP of the cookbook. That is equivalent: prepend_path mutates ENV at COMPILE
# time and is unconditional (it does not probe for the binary), while the
# installs above are converge-time resources. The first consumer either way is
# a LATER cookbook's compile-time probe — ssh-keys, the next include in
# roles/foundation. Keeping it in one place is what stops the two arms from
# drifting apart.
prepend_path("/usr/local/bin")
