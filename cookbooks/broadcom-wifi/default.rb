%w(bcmwl-kernel-source network-manager).each do |pkg|
  package pkg do
    action :install
    user node[:setup][:install_user]
  end
end
