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
# xcode-select --install launches a GUI dialog and returns immediately,
# so we poll until the CLT installation is complete.
execute "install and wait for Xcode CLT" do
  command <<~BASH
    xcode-select --install 2>/dev/null || true
    echo "Waiting for Xcode Command Line Tools installation..."
    until xcode-select -p > /dev/null 2>&1; do
      sleep 5
    done
    echo "Xcode Command Line Tools installed."
  BASH
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

# Install xcodegen via mise (pre-built binary from github:yonaskolb/XcodeGen releases).
# mise_tool handles `mise install` + `mise use --global` + idempotency guards.
mise_tool "xcodegen" do
end

# Accept Xcode license if Xcode.app is installed
execute "sudo xcodebuild -license accept" do
  only_if "test -d /Applications/Xcode.app"
  not_if "xcodebuild -license check 2>&1 | grep -q 'agreed'"
end
