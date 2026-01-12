# frozen_string_literal: true

case node[:platform]
when "darwin"
  include_cookbook "xcode"
when "ubuntu"
  package "build-essential" do
    user node[:setup][:system_user]
  end
when "arch"
  package "base-devel"
else
  raise "Unsupported platform: #{node[:platform]}"
end
