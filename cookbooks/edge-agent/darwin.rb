# frozen_string_literal: true
#
# edge-agent (macOS): Nuimo BLE → Roon/Hue controller, published as a crate on
# crates.io. Tracks the latest stable release via mise's cargo backend with
# @latest semantics (see common.rb for the install + config half).
#
# macOS wraps the mise-resolved binary in an .app bundle
# (~/Applications/EdgeAgent.app) so macOS Local Network Privacy can register a
# grant keyed by CFBundleIdentifier. Without the bundle + Info.plist, LAN
# access under launchd returns `No route to host (os error 65)` even though
# SSH-launched runs work fine. After mitamae writes the bundle, the user must
# run the .app interactively once to approve the LAN / BLE dialogs; the grant
# survives binary replacement because it keys on the (stable) bundle ID rather
# than the binary's cdhash.
#
# Layout:
#   - mise install cargo:edge-agent[features=hue,locked=true]@latest
#       → ~/.local/share/mise/installs/cargo-edge-agent/<version>/bin/edge-agent
#       → ~/.local/share/mise/shims/edge-agent (active-version shim)
#   - $XDG_CONFIG_HOME/edge-agent/config.toml   (per-host config from files/config-<variant>.toml)
#   - $XDG_STATE_HOME/edge-agent/               (tokens, cache, stdout/stderr logs)
#
# Host identity is resolved once by cookbooks/host-profile (node[:profile][:label]
# = "pro"/"air"/"neo", nil on non-fleet hosts; air matches via its factory-serial
# hostname_override, neo via its ohnos-macbook alias). variant == the label, so the
# per-host config-<variant>.toml selection in common.rb reads it directly instead of
# re-deriving identity from `hostname -s` + a serial-hostname hash. Hosts not in
# the host-profile FLEET table are skipped — same pattern as ssh-keys.
#
# Linux counterpart: linux.rb (systemd --user unit).

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
mise_bin = "#{home}/.local/bin/mise"

# mise install/upgrade + APM secrets + config.toml + state dir.
include_recipe "common"

app_bundle = "#{home}/Applications/EdgeAgent.app"
bundle_exec = "#{app_bundle}/Contents/MacOS/edge-agent"
bundle_launcher = "#{app_bundle}/Contents/MacOS/edge-agent-launcher"
bundle_info = "#{app_bundle}/Contents/Info.plist"
launchd_plist = "#{home}/Library/LaunchAgents/com.shin1ohno.edge-agent.plist"

directory "#{home}/Applications" do
  owner user
  group node[:setup][:group]
  mode "755"
end

directory "#{app_bundle}/Contents/MacOS" do
  owner user
  group node[:setup][:group]
  mode "755"
end

file bundle_info do
  owner user
  group node[:setup][:group]
  mode "644"
  content <<~PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>com.shin1ohno.edge-agent</string>
        <key>CFBundleName</key>
        <string>EdgeAgent</string>
        <key>CFBundleExecutable</key>
        <string>edge-agent</string>
        <key>CFBundleVersion</key>
        <string>0.0.0</string>
        <key>CFBundleShortVersionString</key>
        <string>0.0.0</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>LSUIElement</key>
        <true/>
        <key>NSLocalNetworkUsageDescription</key>
        <string>Connects to weave-server, Roon core, and Philips Hue bridge on the local network.</string>
        <key>NSBonjourServices</key>
        <array>
            <string>_hue._tcp</string>
            <string>_roon._tcp</string>
        </array>
        <key>NSBluetoothAlwaysUsageDescription</key>
        <string>Connects to Nuimo BLE controller for input routing.</string>
    </dict>
    </plist>
  PLIST
end

# Phase 4 APM: wrapper script that sources apm.env (OTEL_EXPORTER_OTLP_HEADERS)
# then exports OTEL_EXPORTER_OTLP_{ENDPOINT,CERTIFICATE} + OTEL_SERVICE_NAME +
# DEPLOYMENT_ENVIRONMENT before exec'ing the bundle binary. launchd has no
# EnvironmentFile-equivalent for plists, so a wrapper is the cleanest path
# to keep the ApiKey out of the plist (mode 0644, world-readable) while
# still getting it into the process environment. The `[ -f ]` guard makes
# apm.env optional: hosts without AWS auth still run edge-agent (just
# without OTLP telemetry until SSM auth lands). The bundle codesign step
# below uses --deep so it covers the wrapper too — no separate sign needed.
file bundle_launcher do
  owner user
  group node[:setup][:group]
  mode "755"
  content <<~LAUNCHER
    #!/bin/sh
    set -a
    [ -f "$HOME/.config/edge-agent/apm.env" ] && . "$HOME/.config/edge-agent/apm.env"
    set +a
    export OTEL_EXPORTER_OTLP_ENDPOINT=https://apm-server.home.local:8200
    export OTEL_EXPORTER_OTLP_CERTIFICATE="$HOME/.config/edge-agent/apm-ca.crt"
    export OTEL_SERVICE_NAME=edge-agent
    export DEPLOYMENT_ENVIRONMENT=home
    exec "$(dirname "$0")/edge-agent" "$@"
  LAUNCHER
end

# Sync binary + ad-hoc sign + reload launchd whenever the mise-resolved binary
# is newer than the bundled copy (or the copy is missing). `mise where` returns
# the active install dir at converge time, so this picks up any version bump
# `mise install ...@latest` produced earlier in the run. `-nt` is true when the
# right-hand side is *not newer*, so `not_if` fires when the bundle is up to
# date. The unload tolerates "not currently loaded" (first run before
# interactive bootstrap) via `2>/dev/null || true`; load is only reached if cp
# + codesign succeeded so a failing codesign leaves the old binary + launchd
# state intact.
execute "sync EdgeAgent.app binary, codesign, and reload launchd" do
  command "src=\"$(#{mise_bin} where cargo:edge-agent)/bin/edge-agent\" && " \
          "cp -f \"$src\" #{bundle_exec} && " \
          "codesign --force --deep --sign - #{app_bundle} && " \
          "{ launchctl unload #{launchd_plist} 2>/dev/null || true; } && " \
          "launchctl load #{launchd_plist}"
  user user
  only_if "test -x \"$(#{mise_bin} where cargo:edge-agent 2>/dev/null)/bin/edge-agent\""
  not_if  "test -x #{bundle_exec} && ! [ \"$(#{mise_bin} where cargo:edge-agent 2>/dev/null)/bin/edge-agent\" -nt #{bundle_exec} ]"
end

directory "#{home}/Library/LaunchAgents" do
  owner user
  group node[:setup][:group]
  mode "755"
end

file launchd_plist do
  owner user
  group node[:setup][:group]
  mode "644"
  content <<~PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.shin1ohno.edge-agent</string>
        <key>ProgramArguments</key>
        <array>
            <string>#{bundle_launcher}</string>
        </array>
        <key>EnvironmentVariables</key>
        <dict>
            <key>RUST_LOG</key>
            <string>info</string>
            <key>PATH</key>
            <string>#{home}/.cargo/bin:/usr/local/bin:/usr/bin:/bin</string>
        </dict>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
            <key>SuccessfulExit</key>
            <false/>
        </dict>
        <key>ThrottleInterval</key>
        <integer>30</integer>
        <key>StandardOutPath</key>
        <string>#{home}/.local/state/edge-agent/#{variant}.log</string>
        <key>StandardErrorPath</key>
        <string>#{home}/.local/state/edge-agent/#{variant}.err.log</string>
        <key>WorkingDirectory</key>
        <string>#{home}</string>
    </dict>
    </plist>
  PLIST
end

# First run requires interactive approval of Local Network + Bluetooth dialogs:
#   open ~/Applications/EdgeAgent.app   # dialogs appear, click Allow
#   pkill -f EdgeAgent.app              # cleanup
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.shin1ohno.edge-agent.plist
# The bundle-ID-keyed grant survives future binary replacements via this cookbook.
