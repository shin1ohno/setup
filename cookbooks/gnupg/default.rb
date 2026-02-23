# frozen_string_literal: true

install_package "gnupg" do
  darwin "gnupg"
  ubuntu "gnupg"
end

# Create .gnupg directory with proper permissions
execute "mkdir -p #{node[:setup][:home]}/.gnupg" do
  not_if { Dir.exist?("#{node[:setup][:home]}/.gnupg") }
end

execute "chmod 700 #{node[:setup][:home]}/.gnupg" do
  only_if { Dir.exist?("#{node[:setup][:home]}/.gnupg") }
end

# Add configuration for macOS to use pinentry-mac
if node[:platform] == "darwin"
  template "#{node[:setup][:home]}/.gnupg/gpg-agent.conf" do
    owner node[:setup][:user]
    mode "600"
    source "templates/gpg-agent.conf"
    not_if { File.exist?("#{node[:setup][:home]}/.gnupg/gpg-agent.conf") }
  end

  package "pinentry"  # includes pinentry-tty and pinentry-curses
end

# Add GnuPG to profile
add_profile "gnupg" do
  bash_content <<~EOH
    # GPG Agent configuration
    export GPG_TTY=$(tty)
    # Refresh gpg-agent tty in case user switches into an X session
    gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
  EOH
end
