%w(bcmwl-kernel-source network-manager).each do |pkg|
  package pkg do
    action :install
    user node[:setup][:system_user]
  end
end
