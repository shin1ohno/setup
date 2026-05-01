# frozen_string_literal: true

case node[:platform]
when "darwin"
  include_cookbook "xcode"
when "ubuntu"
  package "build-essential" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' build-essential 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
when "arch"
  package "base-devel"
else
  raise "Unsupported platform: #{node[:platform]}"
end
