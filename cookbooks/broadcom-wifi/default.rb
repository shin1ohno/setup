%w(bcmwl-kernel-source network-manager).each do |pkg|
  package pkg do
    action :install
  end
end
