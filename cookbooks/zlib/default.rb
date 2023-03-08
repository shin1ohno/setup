if node[:platform] != 'darwin'
  install_package 'zlib' do
    ubuntu 'zlib1g-dev'
    arch 'zlib'
  end
end
