# frozen_string_literal: true

directory "#{node[:setup][:root]}/gcloud-cli" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Get user information from node attributes
user = node[:setup][:user]
group = node[:setup][:group]
home = node[:setup][:user_home] || ENV["HOME"]
sdk_dir = "#{home}/google-cloud-sdk"
gcloud_bin = "#{sdk_dir}/bin/gcloud"
zshrc_path = "#{home}/.zshrc"
path_line = "source '#{sdk_dir}/path.zsh.inc'"
completion_line = "source '#{sdk_dir}/completion.zsh.inc'"

case node[:platform]
when "darwin"
  # Detect architecture and set appropriate archive
  arch_cmd = "uname -m"
  arch = `#{arch_cmd}`.strip
  
  if arch == "arm64"
    archive_name = "google-cloud-cli-darwin-arm.tar.gz"
  else
    archive_name = "google-cloud-cli-darwin-x86_64.tar.gz"
  end
  
  archive_path = "#{node[:setup][:root]}/gcloud-cli/#{archive_name}"
  
  execute "curl --silent --fail https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/#{archive_name} -o #{archive_path.shellescape}" do
    user user
    group group
    not_if { FileTest.exist?(archive_path) }
  end
  
  execute "tar -xzf #{archive_path.shellescape} -C #{home}" do
    user user
    group group
    not_if { FileTest.directory?(sdk_dir) }
  end
  
  execute "#{sdk_dir}/install.sh --quiet --usage-reporting=false --path-update=true --command-completion=true --rc-path=#{zshrc_path} --additional-components alpha beta" do
    user user
    group group
    not_if "test -x #{gcloud_bin}"
  end

  profile "gcloud-cli" do
    bash_content <<~EOM
      #{path_line}
      #{completion_line}
    EOM
  end
when "ubuntu", "debian"
  archive_path = "#{node[:setup][:root]}/gcloud-cli/google-cloud-cli-linux-x86_64.tar.gz"
  
  execute "curl --silent --fail https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz -o #{archive_path.shellescape}" do
    user user
    group group
    not_if { FileTest.exist?(archive_path) }
  end
  
  execute "tar -xzf #{archive_path.shellescape} -C #{home}" do
    user user
    group group
    not_if { FileTest.directory?(sdk_dir) }
  end
  
  execute "#{sdk_dir}/install.sh --quiet --usage-reporting=false --path-update=true --command-completion=true --rc-path=#{zshrc_path} --additional-components alpha beta" do
    user user
    group group
    not_if "test -x #{gcloud_bin}"
  end

  profile "gcloud-cli" do
    bash_content <<~EOM
      #{path_line}
      #{completion_line}
    EOM
  end
else
  raise "Unsupported platform: #{node[:platform]}"
end