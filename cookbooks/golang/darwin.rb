# frozen_string_literal: true
#
# golang, darwin half: mise ships a prebuilt Go, and the Xcode Command Line
# Tools already cover the toolchain, so there is nothing to install beyond the
# shared half. linux.rb adds the distro build dependencies first
# (cookbooks/golang/linux.rb); everything else lives in common.rb.

# Ensure mise is installed
include_cookbook "mise"

include_recipe "common"
