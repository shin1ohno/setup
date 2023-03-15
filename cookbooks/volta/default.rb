# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/volta-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

if node[:platform] == "ubuntu"
  git_clone "volta" do
    uri "https://github.com/volta-cli/volta.git"
    cwd node[:setup][:root]
  end

  execute "$HOME/.cargo/bin/cargo build --release" do
    not_if { File.exists? "" }
    cwd "#{node[:setup][:root]}/volta"
  end

  directory "#{ENV["HOME"]}/.volta/bin" do
    user  node[:setup][:user]
    group node[:setup][:user]
    action :create
    mode "744"
  end

  %w(volta volta-migrate volta-shim).each do |b|
    execute "cp #{b} $HOME/.volta/bin/" do
      cwd "#{node[:setup][:root]}/volta/target/release"
      not_if { File.exists? "#{ENV["HOME"]}/.volta/bin/#{b}" }
    end
  end
else
  volta_user = ENV["SUDO_USER"] || ENV.fetch("USER")
  execute "bash #{node[:setup][:root]}/volta-install.sh --skip-setup" do
    user volta_user
    not_if "test -e \"$HOME/.volta/bin/volta\""
  end
end

add_profile "volta" do
  priority 60 # Make sure this is loaded after nodebrew
  bash_content <<-BASH
export VOLTA_HOME=$HOME/.volta
export PATH="$VOLTA_HOME/bin:$PATH"
  BASH
  fish_content <<-FISH
set -gx VOLTA_HOME $HOME/.volta
fish_add_path -m $VOLTA_HOME/bin
  FISH
end
