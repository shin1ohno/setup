# frozen_string_literal: true
#
# build-essential, darwin half: on macOS the toolchain IS the Xcode Command
# Line Tools, so this arm only selects another cookbook.
#
# Split rather than a platform_value because the platforms need different
# RESOURCES — the pre-split default.rb was a `case node[:platform]` whose
# darwin arm resolved to an include and whose linux arms installed distro
# metapackages (cookbooks/build-essential/linux.rb).
include_cookbook "xcode"
