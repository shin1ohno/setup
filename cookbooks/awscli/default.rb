# frozen_string_literal: true

case node[:platform]
when "ubuntu"
  package "awscli"
when "arch"
  package "aws-cli"
when "darwin"
  directory "#{node[:setup][:root]}/awscli" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  pkg_path = "#{node[:setup][:root]}/awscli/AWSCLIV2.pkg"

  execute "curl --silent --fail https://awscli.amazonaws.com/AWSCLIV2.pkg -o #{pkg_path.shellescape}" do
    not_if { FileTest.exist?(pkg_path) }
  end

  execute "sudo -p 'Enter your password to install awscli: ' installer -pkg #{pkg_path.shellescape} -target /" do
    not_if { FileTest.directory?("/usr/local/aws-cli") }
  end

  package "awscli" do
    action :remove
    only_if { FileTest.exist?("#{node[:homebrew][:prefix]}/bin/aws") }
  end

  add_profile "dot-zsh" do
    bash_content <<"EOM"
complete -C '/usr/local/bin/aws_completer' aws
EOM
  end
else
  raise "Unsupported platform: #{node[:platform]}"
end
