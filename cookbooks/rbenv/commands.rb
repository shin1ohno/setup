directory "#{node[:setup][:root]}/rbenv" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  action :create
end

add_profile 'rbenv' do
  priority 10
  bash_content %Q{export PATH="#{node[:setup][:root]}/rbenv:$PATH"\neval "$(#{node[:setup][:root]}/rbenv/rbenv init - --no-rehash)"\n}
  fish_content %Q{set -gx PATH #{node[:setup][:root]}/rbenv $PATH\nsource (#{node[:setup][:root]}/rbenv/rbenv init - --no-rehash | psub)}
end

template "#{node[:setup][:root]}/rbenv/rbenv" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  action :create
  source 'files/usr/share/setup/rbenv/rbenv'
end
