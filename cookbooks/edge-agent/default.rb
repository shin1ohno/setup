# frozen_string_literal: true
#
# Deploy edge-agent per-host config at the XDG location the agent looks up
# on startup. The agent binary itself is installed via `cargo install
# edge-agent` (not managed here); this cookbook only owns the per-host
# runtime layout:
#   - $XDG_CONFIG_HOME/edge-agent/config.toml  (per-host config)
#   - $XDG_STATE_HOME/edge-agent/              (tokens, cache — created empty)
#
# Config variants live under `files/config-<variant>.toml` and are picked
# by matching the lowercase short hostname against the map below. Hosts
# that aren't in the map are skipped — same pattern as ssh-keys.

HOSTNAME_TO_VARIANT = {
  "pro" => "pro",
  "xmhtm6qvqx" => "air", # MacBook Air
}.freeze

current_host = run_command("hostname -s").stdout.strip.downcase
variant = HOSTNAME_TO_VARIANT[current_host]

if variant.nil?
  MItamae.logger.info("edge-agent: hostname '#{current_host}' not in HOSTNAME_TO_VARIANT, skipping")
  return
end

directory "#{node[:setup][:home]}/.config/edge-agent" do
  owner node[:setup][:user]
  mode "755"
end

remote_file "#{node[:setup][:home]}/.config/edge-agent/config.toml" do
  owner node[:setup][:user]
  mode "644"
  source "files/config-#{variant}.toml"
  not_if "test -f #{node[:setup][:home]}/.config/edge-agent/config.toml"
end

directory "#{node[:setup][:home]}/.local/state/edge-agent" do
  owner node[:setup][:user]
  mode "755"
end
