remote_file "#{node[:setup][:root]}/rust-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "#{node[:setup][:root]}/rust-install.sh -y --no-modify-path" do
  not_if { File.exists? "#{ENV["HOME"]}/.cargo/env" }
end

add_profile "cargo" do
  bash_content 'source "$HOME/.cargo/env"'
end

execute "$HOME/.cargo/bin/rustup update stable"
execute "$HOME/.cargo/bin/cargo install bottom --locked" do
  not_if "which btm"
end
