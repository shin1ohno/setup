# frozen_string_literal: true

case node[:platform]
when "darwin"
  include_cookbook "mise"
  mise_tool "java" do
    versions ["corretto-11", "corretto-17"]
    default_version "corretto-17"
  end

  add_profile "java" do
    bash_content "export JAVA_HOME=$($HOME/.local/bin/mise where java@corretto-17 2>/dev/null)\n"
    fish_content "set -gx JAVA_HOME ($HOME/.local/bin/mise where java@corretto-17 2>/dev/null)\n"
  end

  # Cleanup legacy brew casks. Cask name uses '@' which brew normalizes to
  # '@' in `brew list --cask` output (e.g. corretto@11).
  %w(corretto@11 corretto@17).each do |cask|
    execute "brew uninstall --cask #{cask}" do
      only_if { brew_cask?(cask) }
    end
  end
when "ubuntu"
  include_cookbook "apt-source-corretto"
  package "java-common" do
    user node[:setup][:system_user]
  end
else
  raise "Unsupported platform: #{node[:platform]}"
end
