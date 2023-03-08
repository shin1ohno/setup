install_package "zsh" do
  darwin "zsh"
end

zsh_path = case node[:platform]
           when "darwin"
             "#{node[:homebrew][:prefix]}/bin/zsh"
           end

execute " sudo echo #{zsh_path} | sudo tee -a /etc/shells > /dev/null" do
  not_if "grep -q #{zsh_path} /etc/shells"
end

execute "sudo chsh -s #{zsh_path} #{node[:setup][:user]}" do
  not_if !zsh_path || "test $SHELL == #{zsh_path}"
end