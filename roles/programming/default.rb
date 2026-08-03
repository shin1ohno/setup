# frozen_string_literal: true

# Programming role: Programming languages and development environments
# This role installs various programming languages and their toolchains

# Build tools (Xcode Command Line Tools on macOS, the build-essential /
# base-devel metapackage on Linux)
include_platform_cookbook "build-essential"

# Version configuration
node.reverse_merge!(
  rbenv: {
    root: "#{node[:setup][:home]}/.rbenv",
    global_version: "4.0",
    global_gems: %w(bundler itamae ed25519 bcrypt_pbkdf)
  },
  go: {
    versions: %w(1.22.3 1.21.8)
  },
  nodejs: {
    versions: %w(lts 18 20 21)
  },
  python: {
    versions: %w(3.12.2 3.11.8)
  }
)

# Ruby ecosystem with dependencies
include_cookbook "gdbm"
include_cookbook "berkeley-db"
include_platform_cookbook "libffi"  # darwin additionally exports LDFLAGS/CPPFLAGS for the keg-only brew libffi
include_cookbook "libyaml"
include_cookbook "readline"
# ncurses / zlib are Linux-only (cookbooks/<name>/platform marker): macOS
# builds Ruby against the copies in the SDK.
unless node[:platform] == "darwin"
  include_cookbook "ncurses"
  include_cookbook "zlib"
end
include_cookbook "rbenv"
include_cookbook "ruby40"

# Other programming languages
include_cookbook "rust"
include_cookbook "nodejs"
include_platform_cookbook "pm2"  # launchd vs systemd startup wiring
include_platform_cookbook "haskell"  # stack from mise (darwin) vs upstream script (linux)
include_platform_cookbook "golang"   # linux additionally needs the distro build deps

# Python tooling
include_cookbook "uv"
include_platform_cookbook "python"   # linux additionally needs the pyenv build deps

# Development tools and version managers
include_cookbook "mise"
include_platform_cookbook "jdk"      # corretto via mise (darwin) vs apt (linux)

# Cloud development tools
# awscli moved to roles/foundation (ssh-keys depends on it; foundation runs first).
include_cookbook "gcloud-cli"
