# frozen_string_literal: true
#
# golang, linux half: the distro build dependencies that a from-source Go
# build (and cgo) needs, ahead of the shared mise install in common.rb. macOS
# gets these from the Xcode Command Line Tools, so darwin.rb only includes the
# shared half.

# Ensure mise is installed
include_cookbook "mise"

# Install build dependencies for Ubuntu
%w(curl git mercurial make binutils bison gcc build-essential).each do |pkg|
  package pkg do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end

include_recipe "common"
