# frozen_string_literal: true

case node[:platform]
when "darwin"
  execute "brew reinstall --cask corretto@11" do
    not_if %q{/usr/libexec/java_home --verbose 2>&1 | fgrep -q '"Amazon Corretto 11"'}
  end

  execute "brew reinstall --cask corretto@17" do
    not_if %q{/usr/libexec/java_home --verbose 2>&1 | fgrep -q '"Amazon Corretto 17"'}
  end

  add_profile "java" do
    bash_content "export JAVA_HOME=$(/usr/libexec/java_home -v 17)\n"
    fish_content "set -gx JAVA_HOME (/usr/libexec/java_home -v 17)\n"
  end
when "ubuntu"
  include_cookbook "apt-source-corretto"
  package "java-common" do
    user node[:setup][:system_user]
  end
else
  raise "Unsupported platform: #{node[:platform]}"
end
