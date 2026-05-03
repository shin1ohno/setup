# frozen_string_literal: true
directory "#{node[:setup][:root]}/awscli" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end


case node[:platform]
when "ubuntu"
  archive_path = "#{node[:setup][:root]}/awscli/awscliv2.zip"
  package "unzip" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' unzip 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end

  execute "curl --silent --fail https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o #{archive_path.shellescape}" do
    not_if { File.exist?(archive_path) }
  end

  execute "unzip #{archive_path.shellescape} -d #{node[:setup][:root]}/awscli" do
    not_if { File.exist?("#{node[:setup][:root]}/awscli/aws") }
  end

  execute "sudo -p 'Enter your password to install awscli: ' #{node[:setup][:root]}/awscli/aws/install" do
    # Direct filesystem check — `which aws` was failing under mitamae's
    # specinfra wrapper PATH and re-firing the installer, which then
    # errored with "Found preexisting AWS CLI installation".
    not_if "test -d /usr/local/aws-cli/v2/current"
  end
when "darwin"
  pkg_path = "#{node[:setup][:root]}/awscli/AWSCLIV2.pkg"

  execute "curl --silent --fail https://awscli.amazonaws.com/AWSCLIV2.pkg -o #{pkg_path.shellescape}" do
    not_if { File.exist?(pkg_path) }
  end

  execute "sudo -p 'Enter your password to install awscli: ' installer -pkg #{pkg_path.shellescape} -target /" do
    not_if { FileTest.directory?("/usr/local/aws-cli") }
  end

  package "awscli" do
    action :remove
    only_if { File.exist?("#{node[:homebrew][:prefix]}/bin/aws") }
  end

  add_profile "dot-zsh" do
    bash_content <<"EOM"
complete -C '/usr/local/bin/aws_completer' aws
EOM
  end
else
  raise "Unsupported platform: #{node[:platform]}"
end
