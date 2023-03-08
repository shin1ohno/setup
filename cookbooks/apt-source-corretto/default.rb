execute 'curl -LSsf https://apt.corretto.aws/corretto.key | apt-key add -' do
  not_if 'apt-key adv --list-keys 6DC3636DAE534049C8B94623A122542AB04F24E3'
end

template "/etc/apt/sources.list.d/corretto.list" do
  owner 'root'
  group 'root'
  mode '0644'
  notifies :run, "execute[apt-get update]"
end