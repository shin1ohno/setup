return unless node[:platform] == "darwin"

execute "curl -Ls https://raw.githubusercontent.com/daipeihust/im-select/master/install_mac.sh | sh" do
  user node[:setup][:install_user]
end

