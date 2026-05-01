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
  # Read the user's login shell from /etc/passwd directly. `$SHELL` is
  # not always set in mitamae's child shell, and even when it is, it
  # reflects the parent shell's preference rather than the system record.
  not_if {
    next true unless zsh_path
    passwd_shell = run_command("getent passwd #{node[:setup][:user]} 2>/dev/null", error: false).stdout.split(":")[6].to_s.strip
    passwd_shell == zsh_path
  }
end

execute "touch #{node[:setup][:home]}/.zshrc" do
  not_if { File.exist?("#{node[:setup][:home]}/.zshrc") }
end

execute "echo '. #{node[:setup][:root]}/profile' >> ~/.zshrc" do
  not_if "fgrep -q '. #{node[:setup][:root]}/profile' ~/.zshrc"
end
