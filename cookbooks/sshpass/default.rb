package "sshpass" do
  user node[:setup][:install_user]
  not_if "which sshpass"
end

