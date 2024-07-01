package "iperf3" do
  user node[:platform] == "darwin" ? node[:setup][:user] : "root"
end
