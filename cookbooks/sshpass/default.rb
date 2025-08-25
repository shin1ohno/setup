package "sshpass" do
  user node[:setup][:user]
  not_if "which sshpass"
end

