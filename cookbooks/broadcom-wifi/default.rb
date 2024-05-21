%w(bcmwl-kernel-source network-manager).each do |pkg|
  package pkg do
    action :install
    user "root"
  end
end
