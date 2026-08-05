# frozen_string_literal: true

# Zed editor configuration — the LOCAL CLIENT half. Mirrors the
# dot-config-ghostty pattern: stages settings.json + keymap.json + the bundled
# Glassy Nord theme under ~/.config/zed/. Zed auto-reloads these on save, so a
# fresh mitamae apply takes effect without restarting the editor.
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
# Scope: darwin only — this is the UI host. A Linux box reached over SSH runs
# its own headless server, whose settings are a DIFFERENT (much smaller) set:
# see cookbooks/zed-remote-server. Zed's own docs split it that way — the two
# Zeds do not read each other's main settings file — so keymap, fonts and themes
# have no effect server-side and are deliberately absent there.

zed_config_dir = "#{node[:setup][:home]}/.config/zed"
zed_themes_dir = "#{zed_config_dir}/themes"

# ssh_connections is client-side state whose VALUE is site-specific: the hosts a
# given Mac may reach, and the repo paths on them, are not properties of this
# repo. Read them from an optional machine-local file so a private overlay owns
# the value while this cookbook keeps owning the file. Same delivery channel as
# codex's ~/.codex/config-preamble.toml (cookbooks/codex-cli/files/
# generate_config.sh) — a file, because a node attribute cannot cross the
# separate mitamae invocations an overlay wrapper runs.
#
# Contract: a JSON ARRAY of Zed ssh_connections entries. Absent, unreadable or
# empty -> the key is omitted entirely and Zed keeps its own default. The write
# has to land in an EARLIER invocation than this one; the read below is compile
# time, so a same-run writer would be one apply too late.
#
# Ternary, not `if File.exist?`: bin/lint-cookbooks check 1 flags a top-level
# `if ... File.exist?` line (compile-time state read) and a Proc is not exempt
# either, so the predicate goes in an expression and the resource tests a local.
# The rescue covers EPERM/EACCES — a user-space path can be on a synced volume
# that denies the read outright rather than reporting absence.
#
# The content is PARSED before it is spliced, not just read. This cookbook does
# not own the file, and the fragment lands inside settings.json — so a truncated
# or hand-broken file would make the WHOLE settings file invalid JSON and drop
# Zed back to defaults for every setting, not just this one. Validating turns
# that into "one key omitted, one WARN". mitamae ships JSON (see
# cookbooks/lxc-pro-router), so this needs no require.
ssh_connections_path = "#{zed_config_dir}/ssh-connections.local.json"
ssh_connections_json =
  begin
    raw = File.exist?(ssh_connections_path) ? File.read(ssh_connections_path).to_s.strip : ""
    if raw.empty?
      ""
    elsif JSON.parse(raw).is_a?(Array)
      raw
    else
      MItamae.logger.warn(
        "[dot-config-zed] #{ssh_connections_path} is valid JSON but not an " \
        "array of ssh_connections entries — rendering settings.json without " \
        "ssh_connections.",
      )
      ""
    end
  rescue StandardError => e
    MItamae.logger.warn(
      "[dot-config-zed] #{ssh_connections_path} could not be read or parsed " \
      "(#{e.class}: #{e.message}) — rendering settings.json without " \
      "ssh_connections.",
    )
    ""
  end

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
  variables(ssh_connections_json: ssh_connections_json)
  source "templates/settings.json.erb"
end

# Install solargraph into the active rbenv ruby so Zed's Ruby extension
# can spawn the LSP via the absolute shim path pinned in settings.json.
# System ruby (2.6 on macOS) is too old for solargraph's prism dep,
# which is why Zed's auto-install path fails. Paths come from
# node[:rbenv][:root] (roles/programming resolves it before darwin.rb reaches
# this cookbook) rather than a hardcoded ~/.rbenv.
rbenv_bin = "#{node[:rbenv][:root]}/bin/rbenv"
solargraph_shim = "#{node[:rbenv][:root]}/shims/solargraph"

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
#
# cookbooks/zed-remote-server ships a byte-identical copy for the remote side —
# a worktree created in a remote project is created ON the remote, so the hook
# has to exist there too. bin/lint-cookbooks asserts the two stay identical.
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
