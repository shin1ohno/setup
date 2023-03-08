case node[:platform]
when 'darwin'
  include_cookbook 'homebrew-cask-versions'

  execute 'brew reinstall --cask corretto11' do
    not_if %q{/usr/libexec/java_home --verbose 2>&1 | fgrep -q '"Amazon Corretto 11"'}
  end

  execute 'brew reinstall --cask corretto17' do
    not_if %q{/usr/libexec/java_home --verbose 2>&1 | fgrep -q '"Amazon Corretto 17"'}
  end

  add_profile 'java' do
    bash_content "export JAVA_HOME=$(/usr/libexec/java_home -v 17)\n"
    fish_content "set -gx JAVA_HOME (/usr/libexec/java_home -v 17)\n"
  end
when 'ubuntu'
  include_cookbook 'apt-source-corretto'
  package 'java-common'
else
  raise "Unsupported platform: #{node[:platform]}"
end
