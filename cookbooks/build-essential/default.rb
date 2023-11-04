# frozen_string_literal: true

case node[:platform]
when "darwin"
  # Xcode. Unmanaged
when "ubuntu"
  package "build-essential" do
    user "root"
  end
when "arch"
  package "base-devel"
else
  raise "Unsupported platform: #{node[:platform]}"
end
