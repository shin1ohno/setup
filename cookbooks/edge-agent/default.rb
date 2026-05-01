# frozen_string_literal: true
#
# edge-agent: Nuimo BLE → Roon/Hue controller, published as a crate on crates.io.
# Tracks the latest stable release via mise's cargo backend with @latest semantics.
# Per-host deploy:
#   - mise install cargo:edge-agent[features=hue,locked=true]@latest
#       → ~/.local/share/mise/installs/cargo-edge-agent/<version>/bin/edge-agent
#       → ~/.local/share/mise/shims/edge-agent (active-version shim)
#   - $XDG_CONFIG_HOME/edge-agent/config.toml   (per-host config from files/config-<variant>.toml)
#   - $XDG_STATE_HOME/edge-agent/               (tokens, cache, stdout/stderr logs)
#   - Linux  : systemd --user unit pointing at the mise shim, user runs
#              `systemctl --user enable --now edge-agent` (and `restart` after upgrades)
#   - macOS  : wraps the mise-resolved binary in an .app bundle (~/Applications/EdgeAgent.app)
#              so macOS Local Network Privacy can register a grant keyed by
#              CFBundleIdentifier. Without the bundle + Info.plist, LAN access under
#              launchd returns `No route to host (os error 65)` even though SSH-launched
#              runs work fine. After mitamae writes the bundle, user must run the .app
#              interactively once to approve the LAN / BLE dialogs; the grant survives
#              binary replacement because it keys on the (stable) bundle ID rather than
#              the binary's cdhash.
#
# Auto-upgrade: `mise install <spec>@latest` re-resolves @latest on every mitamae run
# and installs the new version automatically when a newer release lands on crates.io.
#
# Hosts that aren't in HOSTNAME_TO_VARIANT are skipped — same pattern as ssh-keys.

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
mise_bin = "#{home}/.local/bin/mise"
edge_spec = "cargo:edge-agent[features=hue,locked=true]"

# Install (and auto-upgrade) via mise's cargo backend. mise resolves @latest each
# call, so a newer crates.io release is picked up on the next mitamae run.
execute "mise install #{edge_spec}@latest" do
  command "#{mise_bin} install '#{edge_spec}@latest'"
  user user
end

execute "mise use --global #{edge_spec}@latest" do
  command "#{mise_bin} use --global '#{edge_spec}@latest'"
  user user
  not_if "grep -q 'cargo:edge-agent' #{home}/.config/mise/config.toml 2>/dev/null"
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
  # macOS: wrap the mise-resolved edge-agent binary in an .app bundle so macOS
  # Local Network Privacy attaches its grant to a stable CFBundleIdentifier. The
  # bundle's copy of the binary must be re-synced + re-signed whenever mise
  # installs a new version (handled below by an mtime check that compares the
  # bundle copy to the live `mise where` install path).

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
      ExecStart=%h/.local/share/mise/shims/edge-agent
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
