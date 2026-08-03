# frozen_string_literal: true
#
# awscli (macOS): the official AWSCLIV2.pkg. The staging directory and the
# /usr/local/bin PATH prepend are shared with linux.rb — see common.rb.

include_recipe "common"

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

# Lazy-load AWS completion. `complete -C` is bash-style and requires
# bashcompinit; loading both at every shell start cost ~5ms. The wrapper
# below pays the cost only on first `aws` invocation, then unfunctions
# itself so subsequent calls go straight to the real binary.
add_profile "dot-zsh" do
  bash_content <<~'EOM'
    aws() {
      unfunction aws
      autoload -U bashcompinit && bashcompinit
      complete -C '/usr/local/bin/aws_completer' aws
      command aws "$@"
    }
  EOM
end
