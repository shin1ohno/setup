package "sshpass" do
  user node[:setup][:system_user]
  not_if "which sshpass"
end

