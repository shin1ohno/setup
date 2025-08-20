# frozen_string_literal: true

install_package "gnupg" do
  darwin "gnupg"
  ubuntu "gnupg"
end

# Create .gnupg directory with proper permissions
execute "mkdir -p #{ENV["HOME"]}/.gnupg" do
  not_if { Dir.exist?("#{ENV["HOME"]}/.gnupg") }
end

execute "chmod 700 #{ENV["HOME"]}/.gnupg" do
  only_if { Dir.exist?("#{ENV["HOME"]}/.gnupg") }
end

# Add configuration for macOS to use pinentry-mac
if node[:platform] == "darwin"
  template "#{ENV["HOME"]}/.gnupg/gpg-agent.conf" do
    owner node[:setup][:user]
    mode "600"
    source "templates/gpg-agent.conf"
    not_if { File.exist?("#{ENV["HOME"]}/.gnupg/gpg-agent.conf") }
  end

  package "pinentry-mac"
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
