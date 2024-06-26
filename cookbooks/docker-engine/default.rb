execute 'update_and_install_deps' do
  command 'apt-get update && apt-get install -y ca-certificates curl'
  not_if 'dpkg -s ca-certificates curl'
  user "root"
end

execute 'add_docker_gpg_key' do
  command 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -'
  not_if 'apt-key list | grep Docker'
  user "root"
end

execute 'add_docker_repo' do
  command 'add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable"'
  not_if 'grep -R "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d'
  user "root"
end

execute 'update_package_index' do
  command 'apt-get update'
  user "root"
end

%w(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin).each do |pkg|
  package pkg do
    action :install
    user "root"
  end
end

# Start and enable Docker service
service 'docker' do
  action [:start, :enable]
  user "root"
end

