package "mosh" do
  user (node[:platform] == "darwin" ? node[:user] : "root")
end
