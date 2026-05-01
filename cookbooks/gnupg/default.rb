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
  # Skip when the directory is already 0700 — `execute "chmod 700"` is
  # otherwise a no-op call every run.
  not_if {
    File.exist?("#{node[:setup][:home]}/.gnupg") &&
      run_command("stat -c %a #{node[:setup][:home]}/.gnupg", error: false).stdout.strip == "700"
  }
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
