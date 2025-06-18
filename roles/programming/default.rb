# frozen_string_literal: true

# Programming role: Programming languages and development environments
# This role installs various programming languages and their toolchains

# Build tools (for Linux)
include_cookbook "build-essential" unless node[:platform] == "darwin"

# Version configuration
node.reverse_merge!(
  rbenv: {
    root: "#{ENV['HOME']}/.rbenv",
    global_version: "3.3",
    global_gems: %w(bundler itamae ed25519 bcrypt_pbkdf)
  },
  go: {
    versions: %w(go1.22.3 go1.21.8)
  },
  nodejs: {
    versions: %w(18 20 21)
  },
  python: {
    versions: %w(3.12.2 3.11.8)
  }
)

# Ruby ecosystem with dependencies
include_cookbook "gdbm"
include_cookbook "berkeley-db"
include_cookbook "libffi"
include_cookbook "libyaml"
include_cookbook "openssl"
include_cookbook "readline"
include_cookbook "ncurses"
include_cookbook "zlib"
include_cookbook "rbenv"
include_cookbook "ruby33"
include_cookbook "ruby32"

# Other programming languages
include_cookbook "rust"
include_cookbook "nodejs"
include_cookbook "haskell"
include_cookbook "golang"

# Python tooling
include_cookbook "uv"
include_cookbook "python"

# Development tools and version managers
include_cookbook "mise"
include_cookbook "jdk"

# Cloud development tools
include_cookbook "awscli"
include_cookbook "gcloud-cli"
