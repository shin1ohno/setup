# frozen_string_literal: true

# Xcode - Apple's IDE for macOS/iOS development
# https://developer.apple.com/xcode/
#
# This cookbook manages:
# 1. xcodes CLI - for downloading and managing Xcode versions
# 2. Xcode Command Line Tools - basic build tools
#
# Note: Xcode.app installation requires Apple ID authentication.
# After running this recipe, manually run: xcodes install --latest

return if node[:platform] != "darwin"

# Ensure Xcode Command Line Tools are installed first
# (Required for xcodes bottle installation and general development)
execute "xcode-select --install" do
  not_if "xcode-select -p > /dev/null 2>&1"
end

# Install xcodes CLI for Xcode version management
# Use homebrew-core formula (has pre-built bottles, no Xcode required)
execute "brew install xcodes" do
  not_if "brew list xcodes"
end

# Install aria2 for faster parallel downloads
execute "brew install aria2" do
  not_if "brew list aria2"
end

# Accept Xcode license if Xcode.app is installed
execute "sudo xcodebuild -license accept" do
  only_if "test -d /Applications/Xcode.app"
  not_if "xcodebuild -license check 2>&1 | grep -q 'agreed'"
end
