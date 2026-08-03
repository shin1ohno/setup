# frozen_string_literal: true
#
# gnupg, darwin half: Homebrew's gnupg plus the `pinentry` formula, which ships
# pinentry-tty and pinentry-curses. Split rather than a platform_value because
# the pinentry package is a DIFFERENT resource per OS -- linux.rb installs
# pinentry-curses through apt behind a dpkg-query guard.
package "gnupg"

# pinentry-tty rather than pinentry-mac: the agent has to work in headless ssh
# sessions too, and the tty flavour is the one that does. Installed BEFORE
# common.rb renders gpg-agent.conf and reloads the agent, so the reload never
# points a running agent at a binary that is not there yet (the pre-split
# recipe installed this AFTER the reload -- the linux half already had the
# ordering right and this brings darwin in line).
package "pinentry"

# Pinentry binary path the shared gpg-agent.conf template renders. The literal
# /opt/homebrew is deliberate: the pre-split recipe hardcoded it, and rewriting
# it to node[:homebrew][:prefix] would change the rendered config on an Intel
# Mac (/opt/brew) -- a separate change from this migration.
node.reverse_merge!(gnupg: { pinentry_program: "/opt/homebrew/bin/pinentry-tty" })

include_cookbook "gnupg::common"
