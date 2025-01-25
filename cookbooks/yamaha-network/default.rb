execute "install ansible-pylibssh" do
  command "pip install ansible-pylibssh"
  not_if "pip list | grep ansible-pylibssh"
end

execute "install rtx router ansible module" do
  command "ansible-galaxy collection install yamaha_network.rtx"
  not_if "ansible-galaxy collection list | grep yamaha_network.rtx"
end
