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

# Match any form of the profile source line: tilde (`. ~/.setup_shin1ohno/profile`),
# absolute (`. /Users/.../.setup_shin1ohno/profile`), or `$HOME`-prefixed. The prior
# absolute-only check missed legacy tilde-form lines and re-appended a duplicate
# absolute-form line on every apply, doubling shell startup time.
execute "echo '. #{node[:setup][:root]}/profile' >> ~/.zshrc" do
  not_if "fgrep -q 'setup_shin1ohno/profile' ~/.zshrc"
end

# Disable system-wide rc files via `unsetopt GLOBAL_RCS` in ~/.zshenv.
# Saves ~10-20ms of shell startup by skipping /etc/zprofile, /etc/zshrc,
# /etc/zlogin (which mostly set HISTFILE/SIZE and a few terminfo keymaps).
# Those defaults are replicated in profile.d/10-dot-zsh.sh.
#
# Must live in .zshenv because .zshrc runs AFTER /etc/zshrc — too late.
# /etc/zshenv has already run by .zshenv time (acceptable; it's nearly
# always empty on macOS).
execute "touch #{node[:setup][:home]}/.zshenv" do
  not_if { File.exist?("#{node[:setup][:home]}/.zshenv") }
end

execute "echo 'unsetopt GLOBAL_RCS' >> #{node[:setup][:home]}/.zshenv" do
  not_if "fgrep -q 'unsetopt GLOBAL_RCS' #{node[:setup][:home]}/.zshenv"
end
