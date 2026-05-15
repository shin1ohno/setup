# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/bun-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "#{node[:setup][:root]}/bun-install.sh" do
  not_if { File.exist? "#{node[:setup][:home]}/.bun/bin/bun" }
end

add_profile "bun" do
  bash_content <<~'END'
    # Lazy-load bun completion. PATH is set eagerly so `which bun` works;
    # the completion file (~40ms to source) loads only on first bun call.
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    bun() {
      unset -f bun
      [ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"
      bun "$@"
    }
  END
end

execute "$HOME/.bun/bin/bun upgrade" do
  only_if { File.exist? "#{node[:setup][:home]}/.bun/bin/bun" }
end

