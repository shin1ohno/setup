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
# Host identity is resolved once by cookbooks/host-profile (node[:profile][:label]
# = "pro"/"air"/"neo", nil on non-fleet hosts; air matches via its factory-serial
# hostname_override, neo via its ohnos-macbook alias). variant == the label, so the
# per-host config-<variant>.toml selection below reads it directly instead of
# re-deriving identity from `hostname -s` + a serial-hostname hash. Hosts not in
# the host-profile FLEET table are skipped — same pattern as ssh-keys.

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
edge_spec = "cargo:edge-agent[features=hue,locked=true]"

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

# Phase 4 APM env paths (used by both Linux systemd --user and macOS launchd
# wrapper). OTEL_EXPORTER_OTLP_HEADERS holds the edge-agent-scoped ApiKey
# fetched from SSM at apply time (mode 0600). apm-ca.crt is the home APM
# Server CA cert; tonic's gRPC TLS handshake verifies against es_ca (not in
# OS roots) so without this the SDK silently drops every batch with "TLS
# handshake error: EOF" visible only in apm-server logs.
apm_env_path = "#{home}/.config/edge-agent/apm.env"
apm_ca_path  = "#{home}/.config/edge-agent/apm-ca.crt"

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

# Phase 4 APM: fetch the per-host ApiKey and CA cert from SSM. Skip when
# both files already exist — SSM regen on every apply would rotate the
# .env mtime, and we want that only when the key/CA itself changes
# (manual rotation via bin/issue-apm-api-keys.sh or es_ca regen). Auth
# gate fails-soft in non-TTY contexts so fresh hosts without AWS creds
# still converge the rest of the recipe; the resulting EnvironmentFile
# is consumed with `-` prefix (systemd) / sourced under `[ -f ]` guard
# (launchd wrapper) so its absence is non-fatal.
require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/apm/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/apm/api-keys/edge-agent " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/apm/* in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(apm_env_path) && File.exist?(apm_ca_path) },
) do
  execute "generate edge-agent APM env" do
    command <<~SH.strip
      umask 077 && key=$(aws ssm get-parameter \
        --name /monitoring/apm/api-keys/edge-agent \
        --with-decryption \
        --profile #{aws_profile} --region #{aws_region} \
        --query Parameter.Value --output text) && \
        printf 'OTEL_EXPORTER_OTLP_HEADERS=authorization=ApiKey %s\n' "$key" > #{apm_env_path} && \
        chmod 0600 #{apm_env_path}
    SH
    user user
  end

  execute "fetch apm-server CA cert for edge-agent" do
    command "aws ssm get-parameter --name /monitoring/apm/ca/cert " \
            "--profile #{aws_profile} --region #{aws_region} " \
            "--query Parameter.Value --output text > #{apm_ca_path} && " \
            "chmod 0644 #{apm_ca_path}"
    user user
  end
end

remote_file "#{home}/.config/edge-agent/config.toml" do
  owner user
  mode "644"
  source "files/config-#{variant}.toml"
  # Skip when config exists AND no longer references the pre-PVE weave-server
  # endpoint (pro:3101). Hosts still pinned to the old endpoint get the file
  # re-deployed on next mitamae apply. Once neo / air have been migrated, this
  # guard can revert to the simple `test -f` form.
  not_if "test -f #{home}/.config/edge-agent/config.toml && " \
         "! grep -q '192.168.1.20:3101' #{home}/.config/edge-agent/config.toml"
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
  bundle_launcher = "#{app_bundle}/Contents/MacOS/edge-agent-launcher"
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
end
