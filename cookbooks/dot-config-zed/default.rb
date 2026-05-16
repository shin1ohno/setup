# frozen_string_literal: true

# Zed editor configuration. Mirrors the dot-config-ghostty pattern:
# stages settings.json + keymap.json + the bundled Glassy Nord theme
# under ~/.config/zed/. Zed auto-reloads these on save, so a fresh
# mitamae apply takes effect without restarting the editor.
#
# Files:
#   ~/.config/zed/settings.json                — UI, vim mode, theme
#                                                 selector, agent_servers
#   ~/.config/zed/keymap.json                  — tmux-style Ctrl-A
#                                                 prefix for pane nav +
#                                                 agent focus chord
#   ~/.config/zed/themes/glassy_nord.json      — vendored from
#                                                 https://github.com/matt-gilb/zed_glassy-nord
#                                                 (transparent / blurred
#                                                 Nord, dark+light)
#
# Scope: darwin only — Zed runs on linux too but the cookbook does not
# currently install Zed on linux.rb hosts, so config-only deploy would
# be a no-op there. Extend to linux when zed is bare-metal-linux scope.

return if node[:platform] != "darwin"

zed_config_dir = "#{node[:setup][:home]}/.config/zed"
zed_themes_dir = "#{zed_config_dir}/themes"

directory zed_config_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

directory zed_themes_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{zed_config_dir}/settings.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  # Zed reads from this path; 600 matches the live file's permissions
  # (Zed historically writes 600 since it can contain API tokens for
  # extension model providers).
  mode "600"
  source "files/settings.json"
end

remote_file "#{zed_config_dir}/keymap.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/keymap.json"
end

remote_file "#{zed_themes_dir}/glassy_nord.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/themes/glassy_nord.json"
end
