# frozen_string_literal: true
#
# edge-agent (Linux): Nuimo BLE → Roon/Hue controller, published as a crate on
# crates.io. Tracks the latest stable release via mise's cargo backend with
# @latest semantics (see common.rb for the install + config half).
#
# Linux runs it as a `systemd --user` unit pointing at the mise shim; the user
# runs `systemctl --user enable --now edge-agent` once (and `restart` after
# upgrades) because systemctl --user needs a DBus session mitamae does not have.
#
# Layout:
#   - mise install cargo:edge-agent[features=hue,locked=true]@latest
#       → ~/.local/share/mise/installs/cargo-edge-agent/<version>/bin/edge-agent
#       → ~/.local/share/mise/shims/edge-agent (active-version shim)
#   - $XDG_CONFIG_HOME/edge-agent/config.toml   (per-host config from files/config-<variant>.toml)
#   - $XDG_STATE_HOME/edge-agent/               (tokens, cache, stdout/stderr logs)
#
# Host identity is resolved once by cookbooks/host-profile (node[:profile][:label]
# = "pro"/"air"/"neo", nil on non-fleet hosts). variant == the label, so the
# per-host config-<variant>.toml selection in common.rb reads it directly instead of
# re-deriving identity from `hostname -s` + a serial-hostname hash. Hosts not in
# the host-profile FLEET table are skipped — same pattern as ssh-keys.
#
# macOS counterpart: darwin.rb (.app bundle + launchd).

variant = node[:profile][:label]

if variant.nil?
  MItamae.logger.warn(
    "edge-agent: host '#{node[:profile][:hostname]}' is not a host-profile FLEET " \
    "host (node[:profile][:label] nil) — no edge-agent deployed.",
  )
  return
end

user = node[:setup][:user]
home = node[:setup][:home]

# mise install/upgrade + APM secrets + config.toml + state dir.
include_recipe "common"

directory "#{home}/.config/systemd/user" do
  owner user
  group node[:setup][:group]
  mode "755"
end

file "#{home}/.config/systemd/user/edge-agent.service" do
  owner user
  group node[:setup][:group]
  mode "644"
  content <<~UNIT
    [Unit]
    Description=edge-agent (weave) — #{variant}
    Documentation=https://github.com/shin1ohno/edge-agent
    After=network-online.target docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=%h/.local/share/mise/shims/edge-agent
    EnvironmentFile=-%h/.config/edge-agent/apm.env
    Environment=RUST_LOG=info
    Environment=OTEL_EXPORTER_OTLP_ENDPOINT=https://apm-server.home.local:8200
    Environment=OTEL_EXPORTER_OTLP_CERTIFICATE=%h/.config/edge-agent/apm-ca.crt
    Environment=OTEL_SERVICE_NAME=edge-agent
    Environment=DEPLOYMENT_ENVIRONMENT=home
    Restart=on-failure
    RestartSec=5s

    [Install]
    WantedBy=default.target
  UNIT
end

# systemctl --user needs the user's DBus session — not available to mitamae.
# First-run bootstrap:
#   systemctl --user daemon-reload
#   systemctl --user enable --now edge-agent
# After this cookbook edits the unit (env vars, ExecStart), the user must:
#   systemctl --user daemon-reload
#   systemctl --user restart edge-agent
# for the new OTEL_* / EnvironmentFile= lines to take effect on the
# running process. `daemon-reload` alone updates only the in-memory
# unit spec; `restart` re-execs the binary with the new env.
