# frozen_string_literal: true

install_package "zsh" do
  darwin "zsh"
  ubuntu "zsh"
end

zsh_path = case node[:platform]
           when "darwin"
             "#{node[:homebrew][:prefix]}/bin/zsh"
           when "ubuntu"
             "/usr/bin/zsh"
end

execute " sudo echo #{zsh_path} | sudo tee -a /etc/shells > /dev/null" do
  not_if "grep -q #{zsh_path} /etc/shells"
end

execute "sudo chsh -s #{zsh_path} #{node[:setup][:user]}" do
  not_if !zsh_path || "test $SHELL == #{zsh_path}"
end

execute "touch #{node[:setup][:home]}/.zshrc" do
  not_if { File.exist?("#{node[:setup][:home]}/.zshrc") }
end

execute "echo '. #{node[:setup][:root]}/profile' >> ~/.zshrc" do
  not_if "fgrep -q '. #{node[:setup][:root]}/profile' ~/.zshrc"
end
