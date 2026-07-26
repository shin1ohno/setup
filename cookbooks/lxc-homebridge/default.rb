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
#   - homebridge-echonet-lite-plus drives ECHONET Lite directly (UDP 3610,
#     multicast group 224.0.23.0) and maps the home-air-conditioner class
#     (EOJ 0130) onto a HeaterCooler service.
#
# It replaced homebridge-echonet-lite-aircon, which worked for control but
# could not keep HomeKit's readings current: it had no polling, so a
# characteristic refreshed only when a controller explicitly read it or the
# device pushed an ECHONET INF announcement. These aircons announce nothing,
# so HomeKit showed HAP's initial values indefinitely — 0 °C current
# temperature, 16 °C thresholds, against real readings of 24 / 29 °C and a
# 25 °C setpoint. homebridge-echonet-lite-plus polls on an interval
# (pollInterval, seeded below) and accepts an explicit device-IP list, which
# also removes the reliance on lossy multicast discovery.
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
# This cookbook only jq-seeds the platform stanza once, if absent — so a
# UI-managed config keeps converging without being overwritten.
#
# Networking note: both HomeKit (mDNS 224.0.0.251) and ECHONET Lite
# (224.0.23.0) need LAN multicast, which is why CT 120 sits on vmbr1 with its
# own MAC on 192.168.1.0/24 — no NAT, no docker bridge in the path.
#
# Two operational facts, both measured on this LAN (2026-07-26):
#
#   1. Multicast discovery is LOSSY here; unicast is not. A single multicast
#      Get to 224.0.23.0 drew replies in roughly a quarter to a half of
#      attempts, while unicast Gets to the same units answered 9/10 and 7/10
#      (Wi-Fi power-save buffering of group-addressed frames is the usual
#      cause). Hence knownDeviceIps in the seeded stanza: every aircon that
#      matters is probed by unicast and discovery stops being a coin flip.
#      When an aircon is still missing, stop homebridge, confirm the unit
#      answers `echonet-discover --sweep` (the probe needs 3610, so it only
#      runs while the service is down), then start homebridge. Use stop/start,
#      never `restart`, for the reason documented at the restart resource.
#
#   2. Accessory identity is IP-derived, so every aircon MUST hold a stable
#      IP — give each one a DHCP binding in home-monitor/devices.tf. EPC 0x83
#      (identification number) comes back empty on these units (Get returns
#      ESV 0x52 Get_SNA with PDC 0), which is what pushes the plugin onto the
#      address as the identity, and a lease change then re-registers the unit
#      as a brand-new accessory while the old one goes dead in the Home app.

return if node[:platform] == "darwin"

HOMEBRIDGE_KEYRING  = "/usr/share/keyrings/homebridge.gpg"
HOMEBRIDGE_APT_LIST = "/etc/apt/sources.list.d/homebridge.list"
HOMEBRIDGE_STORAGE  = "/var/lib/homebridge"
HOMEBRIDGE_CONFIG   = "#{HOMEBRIDGE_STORAGE}/config.json"
HOMEBRIDGE_PLUGIN   = "homebridge-echonet-lite-plus"
HOMEBRIDGE_PLATFORM = "ECHONETLitePlus"
# Platform of the superseded homebridge-echonet-lite-aircon. That package is
# deliberately left installed — rollback is then a config edit — but its
# stanza is dropped below, which is what actually unloads it. Two ECHONET
# plugins cannot share UDP 3610.
HOMEBRIDGE_OLD_PLATFORM = "EchonetLiteAircon"
ECHONET_DISCOVER    = "/usr/local/bin/echonet-discover"
ECHONET_REDISCOVER  = "/usr/local/bin/echonet-rediscover"

# Aircons to expose. `ip` is the DHCP-reserved address (source of truth:
# home-monitor/devices.tf — toshiba_ac_1/.28, toshiba_ac_2/.29); `eoj` is the
# ECHONET object, 013001 for a home air conditioner. The plugin keys its
# per-device settings on "<ip>-<eoj>" and defaults every newly discovered
# device to hidden, so seeding these entries with enabled=true is what puts
# them in HomeKit without a trip through the plugin's custom UI.
#
# Add the Eolia units here once they answer discovery (they need ECHONET Lite
# switched on per-unit in the Eolia app first) AND have a DHCP reservation —
# the reservation is not optional, see the accessory-identity note above.
#
# `epcs` pins which ECHONET properties are synced per device, and pinning them
# is what makes the temperature control appear. HeaterCooler's mandatory
# characteristics (Active, Current/Target state, CurrentTemperature) are added
# by HAP no matter what, but the setpoint sliders are OPTIONAL characteristics
# that the plugin only creates once a decoded `targetTemperature` (EPC B3)
# arrives. Left to itself the plugin polls whatever it happened to learn from
# the device's property map, and B3 never made it into that set here — so
# HomeKit showed an aircon it could switch on but not set. The units answer B3
# fine (it is in both the Get and Set maps: `80 81 82 86 88 89 8a 8c 8f 93 9d
# 9e 9f a0 b0 b3 bb be c6 cf` readable, `80 81 8f 93 a0 b0 b3 cf` writable),
# so requesting it explicitly is all it takes.
#
#   80 operation status   -> Active
#   b0 operation mode     -> TargetHeaterCoolerState
#   b3 target temperature -> Cooling/HeatingThresholdTemperature
#   bb room temperature   -> CurrentTemperature
node.reverse_merge!(
  lxc_homebridge: {
    aircons: [
      { ip: "192.168.1.28", eoj: "013001", name: "Toshiba Aircon 1" },
      { ip: "192.168.1.29", eoj: "013001", name: "Toshiba Aircon 2" },
    ],
    epcs: %w[80 b0 b3 bb],
    poll_interval: 60,
  },
)

aircons       = node[:lxc_homebridge][:aircons]
epcs          = node[:lxc_homebridge][:epcs]
poll_interval = node[:lxc_homebridge][:poll_interval]

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

# A plain `systemctl restart` loses the ECHONET Lite plugin. The homebridge
# child process outlives the unit's stop by a second or two, and it still
# holds UDP 3610 when the new instance starts; node-echonet-lite has no bind
# retry, so the plugin dies at boot with
#   Failed to initialize Echonet Lite: bind EADDRINUSE 0.0.0.0:3610
# and — because that error only aborts discovery, not Homebridge — the bridge
# comes up looking healthy with zero aircons. Stop, wait for the port to
# actually clear, then start. Observed on every restart until this landed.
execute "restart homebridge" do
  command <<~SH
    set -eu
    sudo systemctl stop homebridge
    for _ in $(seq 1 30); do
      ss -uln | grep -q ':3610' || break
      sleep 1
    done
    if ss -uln | grep -q ':3610'; then
      echo "[lxc-homebridge] WARNING: UDP 3610 still held 30s after stop; starting anyway — check that the ECHONET Lite platform initialised" >&2
    fi
    sudo systemctl start homebridge
  SH
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

# 7. Platform stanza. Seeds the plugin's configuration once and swaps out the
# superseded plugin's stanza in the same edit, because both bind UDP 3610 and
# only one can win.
#
# Everything the stanza carries is here for a measured reason:
#
#   pollInterval   — the predecessor (homebridge-echonet-lite-aircon) had no
#                    polling at all. It refreshed a characteristic only when a
#                    controller explicitly read it or the device announced a
#                    change via ECHONET INF. These aircons announce nothing,
#                    so HomeKit sat on HAP's initial values forever: current
#                    temperature 0 °C and threshold 16 °C while the units
#                    actually read 24 / 29 °C and were set to 25 °C.
#   knownDeviceIps — multicast discovery drops replies here (a single Get to
#                    224.0.23.0 drew answers in roughly a quarter to a half of
#                    attempts, while unicast Gets to the same units answered
#                    9/10 and 7/10). Naming the IPs makes discovery
#                    deterministic instead of a coin flip at every start.
#   deviceSettings — the plugin hides every newly discovered device by default
#                    and keys per-device settings on "<ip>-<eoj>". Seeding the
#                    entries with enabled=true is what publishes them to
#                    HomeKit without a trip through the plugin's custom UI.
#
# The guard makes this a one-shot: once the new stanza is present and the old
# one is gone, an operator can rename or extend the entry in the Homebridge UI
# and this resource will not fight it. Ownership and mode are copied from the
# existing file rather than assumed, since the deb owns the service user.
#
# The wait loop covers the first apply, where systemd has just started
# homebridge and config.json may be a second or two behind.
aircon_ip  = ->(a) { a[:ip] || a["ip"] }
aircon_eoj = ->(a) { a[:eoj] || a["eoj"] }
aircon_name = ->(a) { a[:name] || a["name"] }

known_device_ips = aircons.map { |a| "\"#{aircon_ip.call(a)}\"" }.join(",")
epc_list         = epcs.map { |e| "\"#{e}\"" }.join(",")
device_settings  = aircons.map do |a|
  "{\"id\":\"#{aircon_ip.call(a)}-#{aircon_eoj.call(a)}\"," \
    "\"name\":\"#{aircon_name.call(a)}\",\"enabled\":true," \
    "\"properties\":[#{epc_list}]}"
end.join(",")

platform_stanza = "{\"name\":\"ECHONET Lite\",\"platform\":\"#{HOMEBRIDGE_PLATFORM}\"," \
                  "\"autoDiscovery\":true,\"knownDeviceIps\":[#{known_device_ips}]," \
                  "\"pollInterval\":#{poll_interval},\"deviceSettings\":[#{device_settings}]}"

execute "seed #{HOMEBRIDGE_PLATFORM} platform in config.json" do
  command <<~SH
    set -eu
    for _ in $(seq 1 30); do
      [ -f #{HOMEBRIDGE_CONFIG} ] && break
      sleep 1
    done
    if [ ! -f #{HOMEBRIDGE_CONFIG} ]; then
      echo "[lxc-homebridge] WARNING: #{HOMEBRIDGE_CONFIG} absent after 30s; platform stanza NOT seeded. Re-run mitamae once homebridge has started." >&2
      exit 0
    fi
    tmp=$(mktemp)
    jq --argjson add '#{platform_stanza}' '
      .platforms = (
        ((.platforms // []) | map(select(.platform != "#{HOMEBRIDGE_OLD_PLATFORM}" and .platform != "#{HOMEBRIDGE_PLATFORM}")))
        + [$add]
      )
    ' #{HOMEBRIDGE_CONFIG} > "$tmp"
    sudo chown --reference=#{HOMEBRIDGE_CONFIG} "$tmp"
    sudo chmod --reference=#{HOMEBRIDGE_CONFIG} "$tmp"
    sudo mv "$tmp" #{HOMEBRIDGE_CONFIG}
  SH
  # jq is a hard dependency of the homebridge package, so it is always present
  # by the time this runs.
  #
  # "Done" means all three of: the new stanza is present, the superseded one is
  # gone, and every managed device pins its EPC list. The last clause is what
  # migrates a host that was seeded before `properties` existed — without it
  # such a host keeps an aircon HomeKit can switch on but not set.
  not_if "test -f #{HOMEBRIDGE_CONFIG} && " \
         "jq -e '[.platforms[]? | select(.platform == \"#{HOMEBRIDGE_PLATFORM}\")] as $p | " \
         "($p | length > 0) and " \
         "([.platforms[]? | select(.platform == \"#{HOMEBRIDGE_OLD_PLATFORM}\")] | length == 0) and " \
         "([$p[0].deviceSettings[]? | select((.properties | type) == \"array\" and (.properties | length) > 0)] " \
         "| length >= #{aircons.length})' " \
         "#{HOMEBRIDGE_CONFIG} >/dev/null"
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

# 9. Periodic re-discovery. The plugin probes knownDeviceIps once, at startup,
# and its poll loop then iterates only over what that probe found — so a unit
# whose reply is dropped there stays unpolled for the entire life of the
# process, with no optional characteristics (no temperature control) while
# still appearing in HomeKit. Measured after one restart: the plugin held at
# "1台" across three poll cycles while both units answered a 4-EPC unicast Get
# 5/5, and writing the marker below recovered the second unit within seconds.
#
# See files/echonet-rediscover.sh for the mechanism and the upstream fix this
# stands in for.
remote_file "#{staging_dir}/echonet-rediscover.sh" do
  source "files/echonet-rediscover.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0755"
end

execute "install echonet-rediscover" do
  command "sudo install -m 0755 -o root -g root #{staging_dir}/echonet-rediscover.sh #{ECHONET_REDISCOVER}"
  not_if "diff -q #{staging_dir}/echonet-rediscover.sh #{ECHONET_REDISCOVER} >/dev/null 2>&1"
end

# The caller stages the units so `source "files/..."` resolves to this
# cookbook; systemd_unit owns install + activation.
rediscover_service_staging = "#{staging_dir}/echonet-rediscover.service"
rediscover_timer_staging   = "#{staging_dir}/echonet-rediscover.timer"

remote_file rediscover_service_staging do
  source "files/echonet-rediscover.service"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

remote_file rediscover_timer_staging do
  source "files/echonet-rediscover.timer"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

systemd_unit "echonet-rediscover.service" do
  staging_path rediscover_service_staging
  start false
end

systemd_unit "echonet-rediscover.timer" do
  staging_path rediscover_timer_staging
end
