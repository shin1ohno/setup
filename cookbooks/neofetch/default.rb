package "neofetch" do
  user (node[:platform] == "darwin" ? node[:user] : "root")
  not_if "which neofetch"
end

