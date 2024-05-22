package "neofetch" do
  user "root"
  not_if "which neofetch"
end

