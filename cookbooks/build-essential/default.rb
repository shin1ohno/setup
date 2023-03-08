case node[:platform]
when 'darwin'
  # Xcode. Unmanaged
when 'ubuntu'
  package 'build-essential'
when 'arch'
  package 'base-devel'
else
  raise "Unsupported platform: #{node[:platform]}"
end
