# frozen_string_literal: true
#
# gnupg, linux half: apt's gnupg plus pinentry-curses. Split rather than a
# platform_value because the pinentry package is a DIFFERENT resource per OS --
# darwin.rb installs Homebrew's `pinentry` formula, which needs none of the
# dpkg-query guard below.
install_package "gnupg" do
  ubuntu "gnupg"
end

# pinentry-curses must be installed before the agent reloads, or gpg-agent
# fails to launch pinentry on the first commit after the config change --
# hence before the common.rb include below, which renders gpg-agent.conf and
# notifies the reload.
package "pinentry-curses" do
  user node[:setup][:system_user]
  not_if { run_command("dpkg-query -W -f='${Status}' pinentry-curses 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
end

# Pinentry binary path the shared gpg-agent.conf template renders.
node.reverse_merge!(gnupg: { pinentry_program: "/usr/bin/pinentry-curses" })

include_cookbook "gnupg::common"
