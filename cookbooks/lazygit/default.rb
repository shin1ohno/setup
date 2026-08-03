# frozen_string_literal: true

include_cookbook "mise"

mise_tool "lazygit"

# Value-only difference: lazygit reads its config from the macOS Application
# Support tree on darwin and from XDG ~/.config elsewhere. The directory and
# remote_file resources below are identical on both, so this is a value
# dispatch rather than a per-OS split. (The linux path keeps its trailing
# slash — the interpolation below yields `.config/lazygit//config.yml`, which
# is the path the already-converged hosts have.)
path = platform_value(
  darwin: "#{node[:setup][:home]}/Library/Application Support/lazygit",
  linux: "#{node[:setup][:home]}/.config/lazygit/",
)

# Drop the Homebrew formula superseded by the mise-managed binary. No platform
# branch: the brew cache backing brew_formula? is written by cookbooks/homebrew
# (darwin-only), so off darwin the lookup reads a missing file, returns [], and
# this resource is skipped — the OS condition already lives in the guard.
package "lazygit" do
  action :remove
  only_if { brew_formula?("lazygit") }
end

directory path do
  user  node[:setup][:user]
  group node[:setup][:group]
  action :create
  mode "744"
end

remote_file "#{path}/config.yml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/config.yml"
end
