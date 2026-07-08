# frozen_string_literal: true
#
# remind — a Swift + EventKit CLI that registers TODOs into macOS Reminders.
#
# Why EventKit over AppleScript: EventKit talks to the Reminders data-store
# daemon directly (no GUI app launch), is fast/headless, and exposes the full
# reminder model (lists, due-date components, alarms). The tradeoff is a build
# step plus a TCC "Reminders full access" grant on first run.
#
# macOS-only: swiftc + EventKit exist only on darwin. Self-gates so the recipe
# is a no-op if ever reached on Linux.
#
# Idempotency: rebuild only when the shipped source changes (sha256 sentinel)
# or the installed binary is missing. A rebuild changes the ad-hoc signature's
# cdhash, so macOS re-prompts for Reminders access after any source change; for
# a rebuild-stable TCC identity, sign with a self-signed / Developer ID cert.

return if node[:platform] != "darwin"

home     = node[:setup][:home]
src_dir  = "#{home}/.local/src/remind"
bin_dir  = "#{home}/.local/bin"
bin      = "#{bin_dir}/remind"
sentinel = "#{src_dir}/.build-hash"

directory bin_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

directory src_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[remind.swift Info.plist].each do |f|
  remote_file "#{src_dir}/#{f}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    source "files/#{f}"
  end
end

# Build + ad-hoc sign + install in one atomic shell pipeline. mitamae's execute
# runs via /bin/sh; wrap in bash for `set -o pipefail`. A missing swiftc (Xcode
# CLT not installed yet) is a WARN skip, not a hard failure — the next apply
# retries once the toolchain is present.
build_cmd = <<~CMD.strip
  bash -c '
    set -euo pipefail
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "WARN: swiftc not found (install Xcode CLT: xcode-select --install); skipping remind build" >&2
      exit 0
    fi
    swiftc "#{src_dir}/remind.swift" -o "#{src_dir}/remind" \\
      -framework EventKit -framework Foundation \\
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "#{src_dir}/Info.plist"
    codesign -s - --force "#{src_dir}/remind"
    install -m 755 "#{src_dir}/remind" "#{bin}"
    cat "#{src_dir}/remind.swift" "#{src_dir}/Info.plist" | shasum -a 256 | cut -d" " -f1 > "#{sentinel}"
  '
CMD

execute "build and install remind" do
  command build_cmd
  user node[:setup][:user]
  not_if %(test -x #{bin} && test -f #{sentinel} && [ "$(cat #{sentinel})" = "$(cat #{src_dir}/remind.swift #{src_dir}/Info.plist | shasum -a 256 | cut -d' ' -f1)" ])
end

# --- daemon mode (remindd) — mini-only, opt-in via marker file --------------
# `remindd serve` is a Hummingbird HTTP daemon that accepts LAN + bearer-token
# requests and creates reminders, so OTHER machines can add to THIS Mac's
# Reminders. It is a SEPARATE binary from the `remind` CLI: it uses SPM +
# Hummingbird (~20 transitive deps, first build 2-5 min), so it is confined to
# the host that opts in with `touch ~/.config/remind/daemon-enabled` — NOT every
# Mac that gets the light CLI. Intended host: the always-on home Mac mini.
#
# Security posture (LAN bind + bearer token, plaintext HTTP) and the mini GUI-
# session / TCC precondition are documented in README.md. Do NOT enable this on
# a roaming laptop (0.0.0.0 would follow it onto untrusted networks).
daemon_marker   = "#{home}/.config/remind/daemon-enabled"
daemon_gate     = "test -f #{daemon_marker}"
config_dir      = "#{home}/.config/remind"
token_file      = "#{config_dir}/token"
daemon_src      = "#{home}/.local/src/remindd"
daemon_bin      = "#{bin_dir}/remindd"
daemon_sentinel = "#{daemon_src}/.build-hash"
log_dir         = "#{home}/.local/var/log"
agents_dir      = "#{home}/Library/LaunchAgents"
plist           = "#{agents_dir}/be.ohno.remindd.plist"
pkg_dir         = File.join(File.dirname(__FILE__), "files", "daemon")

# Every daemon resource is gated at CONVERGE time by `only_if #{daemon_gate}`
# (a shell test on the opt-in marker), NOT a compile-time `if File.exist?`
# wrapper — the latter evaluates pre-converge and trips the cookbook lint.
# Resources are always declared and no-op on hosts without the marker.

directory config_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "700"
  action :create
  only_if daemon_gate
end

[log_dir, agents_dir].each do |d|
  directory d do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
    only_if daemon_gate
  end
end

# Bearer token — generate once, 0600, under umask 077 (no world-readable window).
execute "generate remind daemon token" do
  command "bash -c 'umask 077; openssl rand -hex 32 > #{token_file}'"
  user node[:setup][:user]
  only_if daemon_gate
  not_if "test -s #{token_file}"
end

# Build remindd (SPM + Hummingbird) + ad-hoc sign + install. Idempotent via a
# source sentinel: rebuild only when the package sources change or the binary
# is missing. The .build cache is preserved across source changes (no rm -rf).
# swift-missing is a WARN skip, like the CLI's swiftc guard above.
daemon_build = <<~CMD.strip
  bash -c '
    set -euo pipefail
    if ! command -v swift >/dev/null 2>&1; then
      echo "WARN: swift not found (install Xcode CLT: xcode-select --install); skipping remindd build" >&2
      exit 0
    fi
    mkdir -p #{daemon_src}
    cp -R #{pkg_dir}/. #{daemon_src}/
    cd #{daemon_src}
    swift build -c release
    codesign -s - --force .build/release/remindd
    install -m 755 .build/release/remindd #{daemon_bin}
    ( cd #{daemon_src} && find Package.swift Sources -type f | sort | xargs cat | shasum -a 256 | cut -d" " -f1 ) > #{daemon_sentinel}
  '
CMD

execute "build and install remindd" do
  command daemon_build
  user node[:setup][:user]
  only_if daemon_gate
  not_if %(test -x #{daemon_bin} && test -f #{daemon_sentinel} && [ "$(cat #{daemon_sentinel})" = "$(cd #{pkg_dir} && find Package.swift Sources -type f | sort | xargs cat | shasum -a 256 | cut -d' ' -f1)" ])
  notifies :run, "execute[reload remindd agent]"
end

# LaunchAgent (user Aqua session — required for TCC Reminders access). KeepAlive
# only on UNCLEAN exit + ThrottleInterval, so a crafted-request crash cannot
# become an unbounded restart loop and a clean exit (gate removed) stays down.
file plist do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>be.ohno.remindd</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{daemon_bin}</string>
        <string>serve</string>
      </array>
      <key>EnvironmentVariables</key>
      <dict>
        <key>REMIND_PORT</key><string>8787</string>
      </dict>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
      <key>ThrottleInterval</key><integer>10</integer>
      <key>StandardOutPath</key><string>#{log_dir}/remindd.log</string>
      <key>StandardErrorPath</key><string>#{log_dir}/remindd.log</string>
    </dict>
    </plist>
  PLIST
  only_if daemon_gate
  notifies :run, "execute[reload remindd agent]"
end

# (Re)load the agent when the plist or binary changes. bootstrap is idempotent
# (|| true if already loaded); kickstart -k restarts to pick up a new binary.
execute "reload remindd agent" do
  command "bash -c 'launchctl bootstrap gui/$(id -u) #{plist} 2>/dev/null || true; launchctl kickstart -k gui/$(id -u)/be.ohno.remindd'"
  user node[:setup][:user]
  action :nothing
  only_if daemon_gate
end
