# frozen_string_literal: true

# Allow callers (e.g. CPU-only LXC entry recipes such as lxc-pro-dev.rb)
# to opt out without forking the llm role. Set node[:llm][:skip_ollama]
# = true before including this cookbook (or include_role "llm").
if node.dig(:llm, :skip_ollama)
  MItamae.logger.info("ollama: skipped (node[:llm][:skip_ollama] set)")
  return
end

case node[:platform]
when "darwin"
  package "ollama" do
    action :install
    not_if "which ollama > /dev/null 2>&1"
  end

  execute "brew services restart ollama"
else # Linux
  remote_file "#{node[:setup][:root]}/ollama-install-linux.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/install.sh"
    only_if { node[:platform] != "darwin" }
  end

  execute "#{node[:setup][:root]}/ollama-install-linux.sh" do
    not_if "which ollama > /dev/null 2>&1"
  end
end
