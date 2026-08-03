# frozen_string_literal: true
#
# build-essential, linux half: the distro metapackage carrying gcc / make /
# libc headers, which rbenv, pyenv and ghcup all compile against. The darwin
# half installs the Xcode Command Line Tools instead
# (cookbooks/build-essential/darwin.rb).
#
# install_package raises on a platform it has no key for, which preserves the
# pre-split `else raise "Unsupported platform"` arm. The ubuntu arm keeps the
# same dpkg-query idempotency guard the helper applies to every linux package.
install_package "build-essential" do
  ubuntu "build-essential"
  arch "base-devel"
end
