# frozen_string_literal: true

if node[:platform] == "darwin"
  execute "brew tap hashicorp/tap && brew update" do
    not_if "brew tap | grep hashicorp/tap"
  end
  package "hashicorp/tap/terraform"
  return
else
  execute "install terraform" do
    command <<-EOF
      wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
      sudo apt update && sudo apt install terraform
    EOF
    user node[:setup][:system_user]
    not_if "which terraform"
  end
end
