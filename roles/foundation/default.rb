# frozen_string_literal: true

# Foundation role: the credential / auth-critical environment, run FIRST.
#
# Establishes the authentication foundation (ssh keys, AWS, gh) before any
# heavy software installation in core/programming/llm/extras. Two reasons:
#   1. Downstream roles depend on it — roles/manage clones private repos over
#      ssh (git@github.com) and codecommit (AWS), so ssh-keys + aws must be in
#      place first.
#   2. On a fresh machine, ssh-keys probes AWS SSM at COMPILE time
#      (require_external_auth). Running the auth-critical chain at the very top
#      surfaces that probe (and any TTY pause for `aws configure`) before the
#      long toolchain installs, not partway through them.
#
# Ordering constraints (do not reshuffle without re-checking):
#   - The directory / profile bootstrap MUST precede homebrew — homebrew writes
#     #{node[:setup][:root]}/homebrew-install.sh and reads profile.d/10-homebrew.sh
#     (cookbooks/homebrew/default.rb:5,11).
#   - On darwin, homebrew MUST precede git — git installs via brew `package`
#     and gh via mise (cookbooks/git/default.rb). mise is dependency-free so
#     `git` drags nothing heavy forward.
#   - awscli MUST precede ssh-keys — ssh-keys fetches the host registry from
#     SSM. (ssh-keys also self-includes awscli as a converge-time backstop; the
#     explicit include here documents the dependency and installs it earlier.)
#   - gnupg / build-essential / ruby-python stacks are NOT auth prerequisites
#     and stay in core/programming — do not pull them forward.

# node[:setup][:root] / profile.d / bin are created by cookbooks/functions/default
# (the universal first include — runs before this role), so they already exist
# here. We only render the profile template, which concatenates profile.d/*.sh.
template "#{node[:setup][:root]}/profile" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "templates/profile"
end

# Package manager (darwin only) — prerequisite for git/gnupg brew packages.
include_cookbook "homebrew" if node[:platform] == "darwin"

# Auth-critical toolchain, in dependency order.
include_cookbook "git"      # darwin: brew git + mise gh / linux: apt git,git-lfs,gh
include_cookbook "ssh"      # ssh client config (no deps)
include_cookbook "awscli"   # self-contained installer; ssh-keys depends on it
include_cookbook "ssh-keys" # SSM host-registry fetch → private key + authorized_keys + ssh config
