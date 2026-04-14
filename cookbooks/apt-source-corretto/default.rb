# frozen_string_literal: true

execute "curl -LSsf https://apt.corretto.aws/corretto.key | sudo apt-key add -" do
  not_if "apt-key adv --list-keys 6DC3636DAE534049C8B94623A122542AB04F24E3"
end

execute "add corretto apt source" do
  command "echo 'deb https://apt.corretto.aws stable main' | sudo tee /etc/apt/sources.list.d/corretto.list > /dev/null"
  not_if "test -f /etc/apt/sources.list.d/corretto.list"
  notifies :run, "execute[apt-get update for corretto]"
end

execute "apt-get update for corretto" do
  command "sudo apt-get update"
  action :nothing
end
