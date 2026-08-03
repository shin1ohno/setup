# frozen_string_literal: true
#
# python, darwin half: the Xcode Command Line Tools plus Homebrew already
# supply the headers pyenv compiles against, so everything darwin needs is the
# shared half. linux.rb installs the distro -dev packages first
# (cookbooks/python/linux.rb).
#
# The pre-split default.rb also carried a darwin-only "openssl homebrew fix"
# arm inside the version loop, keyed on version == "3.12.0". It was dead —
# node[:python][:versions] is 3.12.2 / 3.11.8 in roles/programming and in
# test-cookbook.rb, and 3.12.0 appears in no other versions list — and its
# command string had a pasted "setup -> main" fragment in it since the commit
# that introduced it (15db51d), so reaching it would have aborted the apply
# rather than fixed anything. Dropped with the split instead of being carried
# into a per-OS file.
include_recipe "common"
