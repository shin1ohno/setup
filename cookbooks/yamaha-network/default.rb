execute "install ansible-pylibssh" do
  command "pip install ansible-pylibssh"
  not_if "pip list | grep ansible-pylibssh"
end

execute "install rtx router ansible module" do
  command "ansible-galaxy collection install yamaha_network.rtx"
  not_if "ansible-galaxy collection list | grep yamaha_network.rtx"
end

add_profile "yamaha-network" do
  bash_content <<~'BASH'
    # Retrieve RTX router admin password from AWS SSM Parameter Store
    rtx-admin-pass() {
      aws ssm get-parameter \
        --name "/rtx-routers/$1/admin_password" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --profile sh1admn
    }

    # Retrieve RTX router user password from AWS SSM Parameter Store
    # Usage: rtx-user-pass <router_name> <username>
    rtx-user-pass() {
      aws ssm get-parameter \
        --name "/rtx-routers/$1/user_password/$2" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --profile sh1admn
    }
  BASH
end
