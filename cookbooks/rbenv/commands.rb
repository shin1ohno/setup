# frozen_string_literal: true

directory "#{node[:setup][:root]}/rbenv" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

add_profile "rbenv" do
  priority 10
  bash_content <<~EOS
    # Lazy-load rbenv: shims on PATH so ruby/gem/bundle work immediately;
    # `rbenv init` runs only when the rbenv function is first invoked.
    # Saves ~50-100ms at shell start while preserving full functionality.
    export PATH="#{node[:setup][:root]}/rbenv:#{node[:rbenv][:root]}/shims:$PATH"
    rbenv() {
      unset -f rbenv
      eval "$(#{node[:setup][:root]}/rbenv/rbenv init - --no-rehash)"
      rbenv "$@"
    }
  EOS
  fish_content "set -gx PATH #{node[:setup][:root]}/rbenv #{node[:rbenv][:root]}/shims $PATH\n"
end

template "#{node[:setup][:root]}/rbenv/rbenv" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
  source "files/usr/share/setup/rbenv/rbenv"
end
