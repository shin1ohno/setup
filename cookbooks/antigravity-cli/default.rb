# frozen_string_literal: true

# Google Antigravity CLI (agy), the successor of Gemini CLI.
# https://github.com/google-antigravity/antigravity-cli
# https://antigravity.google/docs/overview?tab=cli

include_cookbook "mise"
# The MCP render below shells out to yq and jq.
include_cookbook "yq"
include_cookbook "jq"

home = node[:setup][:home]
gemini_dir = "#{home}/.gemini"

mise_tool "google-antigravity/antigravity-cli" do
  backend "aqua"
end

# agy supersedes Gemini CLI, so drop the old mise install. ~/.gemini stays:
# agy keeps its own settings, rules and MCP config under it.
execute "remove gemini-cli from mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise unuse --global npm:@google/gemini-cli && " \
          "$HOME/.local/bin/mise uninstall --all npm:@google/gemini-cli && " \
          "$HOME/.local/bin/mise reshim"
  only_if "$HOME/.local/bin/mise list | grep -q 'npm:@google/gemini-cli'"
end

# mise owns upgrades. agy's own background updater would otherwise rewrite the
# binary inside mise's install directory behind mise's back.
add_profile "antigravity-cli" do
  bash_content "export AGY_CLI_DISABLE_AUTO_UPDATE=true\n"
  fish_content "set -gx AGY_CLI_DISABLE_AUTO_UPDATE true\n"
end

# Owner-only: agy stores MCP OAuth tokens and server credentials under ~/.gemini.
[gemini_dir, "#{gemini_dir}/config"].each do |dir|
  directory dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "700"
    action :create
  end
end

# agy reads its global rules from ~/.gemini/AGENTS.md and, in the CLI only,
# global skills from ~/.gemini/skills/. The claude-code cookbook deploys the
# shared layer to ~/.agents/ (AGENTS.md and skills/), which Claude Code and Codex
# already read; link both here so the three agents load the same text. The links
# are created even if the targets do not exist yet, so cookbook order does not
# matter. A hand-made file or directory is moved aside under a timestamped name,
# never overwritten; a symlink pointing elsewhere is replaced (`ln -s` onto a
# symlink to a directory would otherwise nest the new link inside it).
{
  "AGENTS.md" => "-f",
  "skills" => "-d",
}.each do |name, test_flag|
  path = "#{gemini_dir}/#{name}"
  target = "#{home}/.agents/#{name}"

  execute "preserve existing ~/.gemini/#{name} before linking" do
    command "mv #{path} #{path}.pre-agents-link.$(date +%Y%m%d%H%M%S)"
    only_if "test #{test_flag} #{path} && ! test -L #{path}"
  end

  execute "replace ~/.gemini/#{name} symlink that points elsewhere" do
    command "rm #{path}"
    only_if "test -L #{path} && test \"$(readlink #{path})\" != #{target}"
  end

  link path do
    to target
    user node[:setup][:user]
  end
end

# MCP servers come from the same servers.yml as Claude Code and Codex.
#
# NO auth gate here, deliberately: generate_mcp_config.sh skips every
# `platforms:`-pinned server (as the codex render does), and the only `ssm:`
# entry in servers.yml (obsidian-api-key) sits on a darwin-pinned server, so this
# render resolves zero SSM parameters. The generator aborts if an unpinned
# server ever gains `ssm:`; adding a require_external_auth gate here is then
# the fix.
#
# The state file records which servers the previous run managed, so a server
# removed from servers.yml is removed from agy too while servers added through
# agy's /mcp stay. Generate, compare, install and clean up in one execute so that
# nothing depends on compile-time file state. cmp leaves an unchanged file alone;
# chmod keeps it owner-only either way, since an existing file may hold server
# credentials added through /mcp.
mcp_yaml_path = File.join(File.dirname(__FILE__), "..", "mcp", "files", "servers.yml")
generator_script = File.join(File.dirname(__FILE__), "files", "generate_mcp_config.sh")
mcp_config_path = "#{gemini_dir}/config/mcp_config.json"
managed_names_path = "#{node[:setup][:root]}/antigravity-mcp-managed-servers.json"
temp_path = "#{node[:setup][:root]}/generated/antigravity_mcp_config.json"

directory "#{node[:setup][:root]}/generated" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

execute "generate and deploy antigravity mcp_config.json" do
  # bash -c: mitamae's execute runs /bin/sh, which is dash on Ubuntu and rejects
  # `set -o pipefail`.
  command <<~CMD.strip
    bash -c '
      set -euo pipefail
      umask 077
      export PATH="#{home}/.local/share/mise/shims:$PATH"
      bash #{generator_script} #{mcp_yaml_path} #{mcp_config_path} #{managed_names_path} #{temp_path}
      if ! cmp -s #{temp_path} #{mcp_config_path}; then
        install -m 600 #{temp_path} #{mcp_config_path}
      fi
      chmod 600 #{mcp_config_path}
      install -m 600 #{temp_path}.managed-names #{managed_names_path}
      rm -f #{temp_path} #{temp_path}.managed-names
    '
  CMD
  user node[:setup][:user]
end
