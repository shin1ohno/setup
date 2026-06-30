# frozen_string_literal: true

# Zed editor configuration. Mirrors the dot-config-ghostty pattern:
# stages settings.json + keymap.json + the bundled Glassy Nord theme
# under ~/.config/zed/. Zed auto-reloads these on save, so a fresh
# mitamae apply takes effect without restarting the editor.
#
# Files:
#   ~/.config/zed/settings.json                — UI, vim mode, theme,
#                                                 agent_servers, format-on-save,
#                                                 inlay hints, git blame gutter,
#                                                 multi-language LSP (Ruby/Rust/
#                                                 Python/TS/Go), edit predictions
#                                                 disabled (no code egress)
#   ~/.config/zed/keymap.json                  — tmux-style Ctrl-A prefix for
#                                                 pane nav + agent focus chord +
#                                                 space-leader LSP/git/comment
#   ~/.config/zed/tasks.json                    — create_worktree hook task that
#                                                 provisions new git worktrees
#                                                 (env copy + mise trust)
#   ~/.config/zed/provision-worktree.sh         — script the hook delegates to
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

template "#{zed_config_dir}/settings.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  # Zed reads from this path; 600 matches the live file's permissions
  # (Zed historically writes 600 since it can contain API tokens for
  # extension model providers).
  mode "600"
  source "templates/settings.json.erb"
end

# Install solargraph into the active rbenv ruby so Zed's Ruby extension
# can spawn the LSP via the absolute shim path pinned in settings.json.
# System ruby (2.6 on macOS) is too old for solargraph's prism dep,
# which is why Zed's auto-install path fails.
rbenv_bin = "#{node[:setup][:home]}/.rbenv/bin/rbenv"
solargraph_shim = "#{node[:setup][:home]}/.rbenv/shims/solargraph"

execute "gem install solargraph (rbenv active)" do
  command "#{rbenv_bin} exec gem install solargraph && #{rbenv_bin} rehash"
  user node[:setup][:user]
  not_if "test -x #{solargraph_shim}"
end

# Install gopls into ~/go/bin so Zed's Go LSP can spawn it via the absolute
# path pinned in settings.json. Zed's own gopls auto-install shells out to
# `go install` and is unreliable under a GUI-launched Zed's stripped PATH,
# so install it deterministically here. Go is managed by mise (see
# cookbooks/golang); the shim is self-contained and resolves the active go
# without needing mise on PATH. only_if guards a fresh machine where the go
# toolchain has not been installed yet (next apply picks it up).
go_shim = "#{node[:setup][:home]}/.local/share/mise/shims/go"
gopls_bin = "#{node[:setup][:home]}/go/bin/gopls"

execute "go install gopls (mise go)" do
  command %(GOPATH="#{node[:setup][:home]}/go" GOBIN="#{node[:setup][:home]}/go/bin" "#{go_shim}" install golang.org/x/tools/gopls@latest)
  user node[:setup][:user]
  not_if "test -x #{gopls_bin}"
  only_if "test -x #{go_shim}"
end

remote_file "#{zed_config_dir}/keymap.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/keymap.json"
end

# Script invoked by the create_worktree hook in tasks.json. Provisions a freshly
# created git worktree (copies gitignored env files + `mise trust`) so a Parallel
# Agents thread can use it immediately. Always exits 0 — never blocks worktree
# creation.
remote_file "#{zed_config_dir}/provision-worktree.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/provision-worktree.sh"
end

# Global Zed tasks. Currently just the create_worktree hook. ERB-templated so the
# hook's command can reference the script by absolute path (GUI Zed has a stripped
# PATH). Project-specific tasks live in each repo's .zed/tasks.json and are not
# touched by this cookbook.
template "#{zed_config_dir}/tasks.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "templates/tasks.json.erb"
end

remote_file "#{zed_themes_dir}/glassy_nord.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/themes/glassy_nord.json"
end
