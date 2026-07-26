# frozen_string_literal: true
#
# cookbooks/lxc-homebridge: Homebridge (HomeKit bridge) for the Panasonic
# Eolia aircons in bedroom / JIN's room. Runs in the dedicated homebridge LXC
# (CT 120 / 192.168.1.84, vmbr1).
#
# Control path is LOCAL ECHONET Lite, not the Panasonic cloud:
#   - Japanese Eolia accounts have no maintained Homebridge plugin. The
#     Comfort Cloud plugin (homebridge-panasonic-ac-platform) states in its
#     README that JP Eolia accounts are unsupported; aurimasniekis/homebridge-eolia
#     has been dead since 2022-03.
#   - homebridge-echonet-lite-aircon (v1.0.3, 2025-07) drives Eolia over
#     ECHONET Lite (UDP 3610, multicast group 224.0.23.0) with zero config —
#     it auto-discovers every responder on the LAN.
#
# PREREQUISITE (device side, not automatable): each aircon needs its wireless
# LAN adapter online AND "ECHONET Lite" enabled in the Eolia app. Without it
# the unit never answers discovery and no accessory appears. Verify with
# /usr/local/bin/echonet-discover (installed below).
#
# Install method: the official Homebridge apt repo. The `homebridge` package
# bundles its own Node runtime (isolated, not on PATH — use `hb-shell`),
# creates the `homebridge` systemd unit, ships homebridge-config-ui-x on
# :8581, and keeps config + plugins under /var/lib/homebridge across updates.
#
# config.json is NOT rendered by this cookbook. The package generates it on
# first start with a random HomeKit PIN and bridge username; those must not
# land in git, and day-to-day plugin/room edits happen in the Homebridge UI.
# This cookbook only jq-merges the EchonetLiteAircon platform stanza once, if
# absent — so a UI-managed config keeps converging without being overwritten.
#
# Networking note: both HomeKit (mDNS 224.0.0.251) and ECHONET Lite
# (224.0.23.0) need LAN multicast, which is why CT 120 sits on vmbr1 with its
# own MAC on 192.168.1.0/24 — no NAT, no docker bridge in the path.
#
# Two operational facts, both measured on this LAN (2026-07-26):
#
#   1. Multicast discovery is LOSSY here; unicast is not. A single multicast
#      Get to 224.0.23.0 drew a reply from the known-good aircons in 1 of 4
#      attempts, while a unicast Get to the same units answered every time
#      (Wi-Fi power-save buffering of group-addressed frames is the usual
#      cause). node-echonet-lite sends the discovery frame 3x at 1s intervals
#      inside the plugin's 60s discovery window, so one startup has roughly a
#      50-60% chance per unit. This is NOT fatal: the plugin is a dynamic
#      platform and caches every accessory it has ever registered, so a unit
#      needs to be discovered exactly once. If an aircon is missing from
#      HomeKit, confirm it answers `echonet-discover --sweep` and then
#      `systemctl restart homebridge` to re-run discovery.
#
#   2. Accessory identity falls back to the IP address. The plugin derives the
#      HomeKit UUID from EPC 0x83 (identification number) and only falls back
#      to the IP when that property comes back empty — which is what the
#      aircons here do (Get returns ESV 0x52 Get_SNA with PDC 0 for 0x83). So
#      every aircon MUST hold a stable IP: give each one a DHCP binding in
#      home-monitor/devices.tf, otherwise a lease change re-registers it as a
#      brand-new accessory and the old one goes dead in the Home app.

return if node[:platform] == "darwin"

HOMEBRIDGE_KEYRING  = "/usr/share/keyrings/homebridge.gpg"
HOMEBRIDGE_APT_LIST = "/etc/apt/sources.list.d/homebridge.list"
HOMEBRIDGE_STORAGE  = "/var/lib/homebridge"
HOMEBRIDGE_CONFIG   = "#{HOMEBRIDGE_STORAGE}/config.json"
HOMEBRIDGE_PLUGIN   = "homebridge-echonet-lite-aircon"
ECHONET_DISCOVER    = "/usr/local/bin/echonet-discover"

staging_dir = "#{node[:setup][:root]}/lxc-homebridge"

# Defensive parent dirs — a fresh PVE LXC bootstrap can reach this cookbook
# before any sibling cookbook has created node[:setup][:root].
directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# 1. apt prerequisites. Debian 13 minimal LXC images ship neither curl nor
# gpg, both of which the keyring step needs.
execute "install apt prerequisites (homebridge)" do
  command "sudo apt-get update -qq && sudo apt-get install -y curl gpg ca-certificates"
  not_if "dpkg -s curl gpg ca-certificates >/dev/null 2>&1"
end

# 2. Repo keyring. apt-key is gone on Debian 12+; bind the keyring via
# signed-by (same shape as cookbooks/apt-source-corretto).
execute "install homebridge apt keyring" do
  command "curl -sSfL https://repo.homebridge.io/KEY.gpg | sudo gpg --dearmor -o #{HOMEBRIDGE_KEYRING} && sudo chmod 0644 #{HOMEBRIDGE_KEYRING}"
  not_if "test -f #{HOMEBRIDGE_KEYRING}"
end

# 3. apt source. Single suite `stable` for every Debian/Ubuntu release —
# the repo is not per-codename.
execute "add homebridge apt source" do
  command "echo 'deb [signed-by=#{HOMEBRIDGE_KEYRING}] https://repo.homebridge.io stable main' | sudo tee #{HOMEBRIDGE_APT_LIST} > /dev/null"
  not_if "test -f #{HOMEBRIDGE_APT_LIST}"
  notifies :run, "execute[apt-get update for homebridge]", :immediately
end

execute "apt-get update for homebridge" do
  command "sudo apt-get update"
  action :nothing
end

# 4. The package itself (bundled Node + systemd unit + config-ui-x).
execute "install homebridge package" do
  command "sudo apt-get install -y homebridge"
  not_if "dpkg -s homebridge >/dev/null 2>&1"
end

# 5. Start the service before touching config.json — the package writes the
# initial config (random PIN + bridge username) on first start, and
# `hb-service add` needs the storage path to exist.
execute "enable + start homebridge" do
  command "sudo systemctl enable --now homebridge"
  not_if "systemctl is-enabled homebridge >/dev/null 2>&1 && systemctl is-active homebridge >/dev/null 2>&1"
end

execute "restart homebridge" do
  command "sudo systemctl restart homebridge"
  action :nothing
end

# 6. ECHONET Lite plugin. `hb-service add` installs into
# #{HOMEBRIDGE_STORAGE}/node_modules using the package's bundled Node — a
# plain `npm install -g` would use a Node that is not on PATH here.
execute "install #{HOMEBRIDGE_PLUGIN}" do
  command "sudo hb-service add #{HOMEBRIDGE_PLUGIN}"
  not_if "test -d #{HOMEBRIDGE_STORAGE}/node_modules/#{HOMEBRIDGE_PLUGIN}"
  notifies :run, "execute[restart homebridge]"
end

# 7. One-time platform stanza merge. Idempotent and non-destructive: the
# not_if means an operator can freely rename/extend the platform entry in the
# UI without this resource fighting it, and ownership/mode are copied from
# the existing file rather than assumed (the package owns the service user).
#
# The wait loop covers the first apply, where systemd has just started
# homebridge and config.json may be a second or two behind.
execute "merge EchonetLiteAircon platform into config.json" do
  command <<~SH
    set -eu
    for _ in $(seq 1 30); do
      [ -f #{HOMEBRIDGE_CONFIG} ] && break
      sleep 1
    done
    if [ ! -f #{HOMEBRIDGE_CONFIG} ]; then
      echo "[lxc-homebridge] WARNING: #{HOMEBRIDGE_CONFIG} absent after 30s; platform stanza NOT merged. Re-run mitamae once homebridge has started." >&2
      exit 0
    fi
    tmp=$(mktemp)
    jq '.platforms = ((.platforms // []) + [{"name":"EchonetLiteAircon","platform":"EchonetLiteAircon"}])' #{HOMEBRIDGE_CONFIG} > "$tmp"
    sudo chown --reference=#{HOMEBRIDGE_CONFIG} "$tmp"
    sudo chmod --reference=#{HOMEBRIDGE_CONFIG} "$tmp"
    sudo mv "$tmp" #{HOMEBRIDGE_CONFIG}
  SH
  # jq is a hard dependency of the homebridge package, so it is always present
  # by the time this runs.
  not_if "test -f #{HOMEBRIDGE_CONFIG} && jq -e '.platforms[]? | select(.platform == \"EchonetLiteAircon\")' #{HOMEBRIDGE_CONFIG} >/dev/null"
  notifies :run, "execute[restart homebridge]"
end

# 8. Discovery probe. The prerequisite ("ECHONET Lite enabled in the Eolia
# app") is device-side and invisible from the service logs — a unit that
# never answers looks identical to a unit that is powered off. This gives a
# one-command answer for both first setup and later "the aircon vanished
# from Home.app" triage.
remote_file "#{staging_dir}/echonet-discover.py" do
  source "files/echonet-discover.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0755"
end

execute "install echonet-discover" do
  command "sudo install -m 0755 -o root -g root #{staging_dir}/echonet-discover.py #{ECHONET_DISCOVER}"
  not_if "diff -q #{staging_dir}/echonet-discover.py #{ECHONET_DISCOVER} >/dev/null 2>&1"
end
