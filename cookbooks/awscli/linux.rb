# frozen_string_literal: true
#
# awscli (Linux): the official v2 zip installer. The staging directory and the
# /usr/local/bin PATH prepend are shared with darwin.rb — see common.rb.
#
# No arch arm: the pre-split `case` raised on anything but ubuntu/darwin, and
# no arch host exists in this fleet. An arch host now resolves to this recipe
# and still fails loudly — install_package raises on a platform it has no
# package name for — rather than converging with the CLI missing.

include_recipe "common"

archive_path = "#{node[:setup][:root]}/awscli/awscliv2.zip"

install_package "unzip" do
  ubuntu "unzip"
end

# Download to a .part file and only publish it once unzip agrees the archive
# is complete. A bare `-o archive_path` guarded on File.exist? leaves a
# truncated zip behind when the transfer dies mid-flight, and the guard then
# treats that corpse as done forever: every later apply skips the download
# and hands the partial file to the unzip below, which fails, which aborts
# the whole run. Observed on CT 120 (homebridge) — a 46 MB fragment of the
# 73 MB zip, re-failing on every converge until it was replaced by hand.
# The integrity check is the guard, so a poisoned cache self-heals.
execute "download awscli v2 installer" do
  command <<~SH.strip
    set -eu
    curl --silent --fail --show-error \\
      https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \\
      -o #{archive_path.shellescape}.part
    unzip -t #{archive_path.shellescape}.part >/dev/null
    mv #{archive_path.shellescape}.part #{archive_path.shellescape}
  SH
  not_if "unzip -t #{archive_path.shellescape} >/dev/null 2>&1"
end

execute "unzip #{archive_path.shellescape} -d #{node[:setup][:root]}/awscli" do
  not_if { File.exist?("#{node[:setup][:root]}/awscli/aws") }
end

execute "sudo -p 'Enter your password to install awscli: ' #{node[:setup][:root]}/awscli/aws/install" do
  # Direct filesystem check — `which aws` was failing under mitamae's
  # specinfra wrapper PATH and re-firing the installer, which then
  # errored with "Found preexisting AWS CLI installation".
  not_if "test -d /usr/local/aws-cli/v2/current"
end
