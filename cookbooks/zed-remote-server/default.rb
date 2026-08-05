# frozen_string_literal: true

# Zed remote-server configuration — the half that runs on a Linux host opened as
# a Zed SSH remote. The Mac client (cookbooks/dot-config-zed) owns the UI; this
# side owns what the headless server does.
#
# Zed splits its settings across three files and the two Zeds do NOT read each
# other's main settings file (https://zed.dev/docs/remote-development):
#   local  ~/.config/zed/settings.json — UI: fonts, theme, keymap, vim,
#                                        ssh_connections
#   remote ~/.config/zed/settings.json — language-server paths and anything else
#                                        affecting server operations (THIS file)
#   project .zed/settings.json         — read by both
#
# So keymap.json and themes/ are deliberately absent here: they would be dead
# files on the remote. Conversely the client has no business pinning this box's
# rbenv path.
#
# Files:
#   ~/.config/zed/settings.json          — lsp binary paths, per-language
#                                           servers, integrated-terminal shell,
#                                           worktree scan exclusions
#   ~/.config/zed/tasks.json             — create_worktree hook (a worktree
#                                           created in a remote project is
#                                           created HERE, so the hook lives here)
#   ~/.config/zed/provision-worktree.sh  — script the hook delegates to
#
# NOT installed: the Zed GUI. Zed downloads a version-matched headless server to
# ~/.zed_server on first connect, so there is nothing for this repo to install.
#
# Scope: linux (see the `platform` marker). Included unconditionally from
# linux.rb — any host this repo manages as bare metal can be opened as a remote,
# and gating on a specific hostname would put a per-host branch back into a
# cookbook and into a code path CI never executes (a CI runner matches no entry
# in cookbooks/host-profile's FLEET table, so node[:profile][:label] is nil).

zed_config_dir = "#{node[:setup][:home]}/.config/zed"

directory zed_config_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

template "#{zed_config_dir}/settings.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  # 600 to match what Zed itself writes (the file can hold API tokens for
  # extension model providers) and the client cookbook's copy.
  mode "600"
  source "templates/settings.json.erb"
end

# Script invoked by the create_worktree hook in tasks.json. Byte-identical to
# cookbooks/dot-config-zed/files/provision-worktree.sh — the hook has to exist on
# whichever machine the worktree is created on, and remote projects create it
# here. bin/lint-cookbooks asserts the two copies stay identical; edit both.
remote_file "#{zed_config_dir}/provision-worktree.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/provision-worktree.sh"
end

template "#{zed_config_dir}/tasks.json" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "templates/tasks.json.erb"
end

# Install solargraph into the active rbenv ruby so Zed's Ruby extension can spawn
# the LSP via the absolute shim path pinned in settings.json. Zed's own
# auto-install resolves against the server process's PATH, which is not the
# login shell's, so pin it. node[:rbenv][:root] is resolved by roles/programming,
# which linux.rb includes before it reaches this cookbook.
rbenv_bin = "#{node[:rbenv][:root]}/bin/rbenv"
solargraph_shim = "#{node[:rbenv][:root]}/shims/solargraph"

execute "gem install solargraph (rbenv active)" do
  command "#{rbenv_bin} exec gem install solargraph && #{rbenv_bin} rehash"
  user node[:setup][:user]
  not_if "test -x #{solargraph_shim}"
  # A host that has not converged rbenv yet would fail the gem install outright,
  # and mitamae has no ignore_failure — the whole run would abort here.
  only_if "test -x #{rbenv_bin}"
end

# Install gopls into ~/go/bin so Zed's Go LSP can spawn it via the absolute path
# pinned in settings.json. Zed's own gopls auto-install shells out to `go
# install` and is unreliable when the spawning process has a stripped PATH. Go is
# managed by mise (see cookbooks/golang); the shim is self-contained and resolves
# the active go without needing mise on PATH. only_if guards a fresh machine
# whose Go toolchain has not converged yet (the next apply picks it up).
go_shim = "#{node[:setup][:home]}/.local/share/mise/shims/go"
gopls_bin = "#{node[:setup][:home]}/go/bin/gopls"

execute "go install gopls (mise go)" do
  command %(GOPATH="#{node[:setup][:home]}/go" GOBIN="#{node[:setup][:home]}/go/bin" "#{go_shim}" install golang.org/x/tools/gopls@latest)
  user node[:setup][:user]
  not_if "test -x #{gopls_bin}"
  only_if "test -x #{go_shim}"
end
