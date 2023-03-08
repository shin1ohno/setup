if node[:platform] != 'darwin'
  install_package 'ncurses' do
    ubuntu 'libncurses-dev'
    arch 'ncurses'
  end
end
