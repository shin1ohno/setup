# frozen_string_literal: true

# Google Workspace CLI (gws)
# https://github.com/googleworkspace/cli

include_cookbook "nodejs"

mise_tool "@googleworkspace/cli" do
  backend "npm"
end

# Agent Skills: generate from the installed gws binary and sync into Claude
# Code's skills dir (~/.claude/skills). Generated rather than vendored so the
# 95-skill set always matches the installed gws version — a mise bump
# regenerates them on the next apply. The skills live with gws (not in
# cookbooks/claude-code) because the tool produces them and pins their version.
home        = node[:setup][:home]
gws_bin     = "#{home}/.local/share/mise/shims/gws"
skills_dir  = "#{home}/.claude/skills"
sentinel    = "#{skills_dir}/.gws-skills-version"
sync_script = "#{node[:setup][:root]}/gws/sync-skills.sh"

directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/gws" do
  mode "755"
end

remote_file sync_script do
  source "files/sync-skills.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Re-run only when the installed gws version differs from the last synced one.
execute "generate + sync gws agent skills" do
  command "bash #{sync_script} #{skills_dir}"
  user node[:setup][:user]
  not_if %{test "$(cat #{sentinel} 2>/dev/null)" = "$(#{gws_bin} --version 2>/dev/null | awk 'NR==1{print $2}')"}
end
