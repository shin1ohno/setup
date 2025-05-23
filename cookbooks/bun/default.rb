# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/bun-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "#{node[:setup][:root]}/bun-install.sh" do
  not_if { File.exists? "#{ENV['HOME']}/.bun/bin/bun" }
end

add_profile "bun" do
  bash_content <<-END 
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
[ -s "/Users/sh1/.bun/_bun" ] && source "/Users/sh1/.bun/_bun"
END
end

execute "$HOME/.bun/bin/bun upgrade" do
  only_if { File.exists? "#{ENV['HOME']}/.bun/bin/bun" }
end

