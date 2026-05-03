# frozen_string_literal: true

# apt-key was removed in Debian 12+ / Ubuntu 22.04+; modern apt sources
# bind the keyring file directly via signed-by.
keyring = "/etc/apt/keyrings/corretto-archive-keyring.gpg"

execute "install corretto apt keyring" do
  command "sudo install -d -m 0755 /etc/apt/keyrings && curl -LSsf https://apt.corretto.aws/corretto.key | sudo gpg --dearmor -o #{keyring}"
  not_if "test -f #{keyring}"
end

execute "add corretto apt source" do
  command "echo 'deb [signed-by=#{keyring}] https://apt.corretto.aws stable main' | sudo tee /etc/apt/sources.list.d/corretto.list > /dev/null"
  not_if "test -f /etc/apt/sources.list.d/corretto.list"
  notifies :run, "execute[apt-get update for corretto]"
end

execute "apt-get update for corretto" do
  command "sudo apt-get update"
  action :nothing
end
