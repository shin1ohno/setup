# frozen_string_literal: true

#
# GPG Backup - Securely backup GPG keys
#
# Two tools:
#   gpg-keychain      - macOS Keychain (local, iCloud sync) - for subkeys on daily machines
#   gpg-master-backup - AWS SSM Parameter Store (remote, cross-platform) - for master key disaster recovery
#
# gpg-keychain is darwin-only, gpg-master-backup is shared, so the shared half
# lives in common.rb and each per-OS recipe includes it after declaring its own
# resources. The bin directory below is duplicated rather than hoisted: it has
# to be declared BEFORE the scripts that land in it, which a single shared tail
# cannot express.

setup_root = node[:setup][:root]
user = node[:setup][:user]

directory "#{setup_root}/bin" do
  owner user
  group node[:setup][:group]
  mode "0755"
end

# gpg-keychain has no linux counterpart (macOS Keychain); the cross-platform
# SSM tool is the whole linux surface.
include_recipe "common"
