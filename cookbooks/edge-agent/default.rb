# frozen_string_literal: true
#
# edge-agent: Nuimo BLE → Roon/Hue controller, published as a crate on crates.io.
# Per-host deploy:
#   - cargo install edge-agent --features hue   → ~/.cargo/bin/edge-agent
#   - $XDG_CONFIG_HOME/edge-agent/config.toml   (per-host config from files/config-<variant>.toml)
#   - $XDG_STATE_HOME/edge-agent/               (tokens, cache, stdout/stderr logs)
#   - Linux  : systemd --user unit, user runs `systemctl --user enable --now edge-agent`
#   - macOS  : wraps the raw cargo binary in an .app bundle (~/Applications/EdgeAgent.app)
#              so macOS Local Network Privacy can register a grant keyed by
#              CFBundleIdentifier. Without the bundle + Info.plist, LAN access under
#              launchd returns `No route to host (os error 65)` even though SSH-launched
#              runs work fine. After mitamae writes the bundle, user must run the .app
#              interactively once to approve the LAN / BLE dialogs; the grant survives
#              binary replacement because it keys on the (stable) bundle ID rather than
#              the binary's cdhash.
#
# Hosts that aren't in HOSTNAME_TO_VARIANT are skipped — same pattern as ssh-keys.

EDGE_AGENT_VERSION = "0.10.0"

HOSTNAME_TO_VARIANT = {
  "pro" => "pro",
  "xmhtm6qvqx" => "air", # MacBook Air,
  "neo" => "neo"
}.freeze

current_host = run_command("hostname -s").stdout.strip.downcase
variant = HOSTNAME_TO_VARIANT[current_host]

if variant.nil?
  MItamae.logger.info("edge-agent: hostname '#{current_host}' not in HOSTNAME_TO_VARIANT, skipping")
  return
end

user = node[:setup][:user]
home = node[:setup][:home]
cargo_bin = "#{home}/.cargo/bin/edge-agent"

# Binary install — idempotent via .crates.toml grep. `cargo install` would also
# short-circuit on a matching version, but the metadata fetch still costs a few
# hundred ms and emits noise; the grep skips the invocation entirely.
execute "cargo install edge-agent #{EDGE_AGENT_VERSION}" do
  command "#{home}/.cargo/bin/cargo install edge-agent --version #{EDGE_AGENT_VERSION} --features hue --locked"
  user user
  cwd home
  not_if "grep -q '\"edge-agent #{EDGE_AGENT_VERSION} (registry' #{home}/.cargo/.crates.toml 2>/dev/null"
end

directory "#{home}/.config/edge-agent" do
  owner user
  mode "755"
end

remote_file "#{home}/.config/edge-agent/config.toml" do
  owner user
  mode "644"
  source "files/config-#{variant}.toml"
  not_if "test -f #{home}/.config/edge-agent/config.toml"
end

directory "#{home}/.local/state/edge-agent" do
  owner user
  mode "755"
end

if node[:platform] == "darwin"
  # macOS: wrap ~/.cargo/bin/edge-agent in an .app bundle so Local Network Privacy
  # attaches its grant to a stable CFBundleIdentifier. The bundle's copy of the
  # binary must be re-synced + re-signed whenever cargo replaces ~/.cargo/bin/edge-agent
  # (handled below by an mtime check).

  app_bundle = "#{home}/Applications/EdgeAgent.app"
  bundle_exec = "#{app_bundle}/Contents/MacOS/edge-agent"
  bundle_info = "#{app_bundle}/Contents/Info.plist"
  launchd_plist = "#{home}/Library/LaunchAgents/com.shin1ohno.edge-agent.plist"

  directory "#{home}/Applications" do
    owner user
    mode "755"
  end

  directory "#{app_bundle}/Contents/MacOS" do
    owner user
    mode "755"
  end

  file bundle_info do
    owner user
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
          <string>#{EDGE_AGENT_VERSION}</string>
          <key>CFBundleShortVersionString</key>
          <string>#{EDGE_AGENT_VERSION}</string>
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

  # Sync binary + ad-hoc sign + reload launchd whenever cargo_bin is newer than
  # the bundled copy (or the copy is missing). `-nt` is true when the right-hand
  # side is *not newer*, so `not_if` fires when the bundle is already up to date.
  # The unload tolerates "not currently loaded" (first run before interactive
  # bootstrap) via `2>/dev/null || true`; load is only reached if cp + codesign
  # succeeded so a failing codesign leaves the old binary + launchd state intact.
  execute "sync EdgeAgent.app binary, codesign, and reload launchd" do
    command "cp -f #{cargo_bin} #{bundle_exec} && " \
            "codesign --force --deep --sign - #{app_bundle} && " \
            "{ launchctl unload #{launchd_plist} 2>/dev/null || true; } && " \
            "launchctl load #{launchd_plist}"
    user user
    only_if "test -x #{cargo_bin}"
    not_if "test -x #{bundle_exec} && ! [ #{cargo_bin} -nt #{bundle_exec} ]"
  end

  directory "#{home}/Library/LaunchAgents" do
    owner user
    mode "755"
  end

  file launchd_plist do
    owner user
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
              <string>#{bundle_exec}</string>
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

else
  # Linux: systemd --user unit.
  directory "#{home}/.config/systemd/user" do
    owner user
    mode "755"
  end

  file "#{home}/.config/systemd/user/edge-agent.service" do
    owner user
    mode "644"
    content <<~UNIT
      [Unit]
      Description=edge-agent (weave) — #{variant}
      Documentation=https://github.com/shin1ohno/edge-agent
      After=network-online.target docker.service
      Wants=network-online.target

      [Service]
      Type=simple
      ExecStart=%h/.cargo/bin/edge-agent
      Environment=RUST_LOG=info
      Restart=on-failure
      RestartSec=5s

      [Install]
      WantedBy=default.target
    UNIT
  end

  # systemctl --user needs the user's DBus session — not available to mitamae.
  # Run once interactively:
  #   systemctl --user daemon-reload
  #   systemctl --user enable --now edge-agent
end
