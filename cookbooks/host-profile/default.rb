# frozen_string_literal: true
#
# host-profile — resolve host facts ONCE and inject them into the node, so
# cookbooks consume them passively instead of each re-deriving identity / OS
# / paths at apply time.
#
# Included by cookbooks/functions/default.rb (the universal first include of
# every entry recipe), so darwin.rb / linux.rb / pve/*.rb all inherit these
# facts WITHOUT an explicit include line and WITHOUT copy-pasting a
# `node.reverse_merge!(setup: {...})` block (previously duplicated 22x).
#
# Sets:
#   node[:setup]    — paths/user/group, platform-resolved
#   node[:homebrew] — prefix/machine, set on ALL platforms (nil-safe on Linux)
#   node[:profile]  — { label:, hostname: } host identity for shared-entry hosts
#
# IDENTITY is resolved OFFLINE from the in-repo FLEET table below — NO SSM /
# AWS dependency, so hosts that previously resolved identity from a hardcoded
# Ruby hash (edge-agent, macos-hub, local-mcp, elastic-agent) keep working
# without credentials. This table is the offline mirror of the identity
# subset of the canonical registry; the source of truth remains
# home-monitor contracts/devices.json (pushed to SSM /host-registry/devices).
# Only hosts that SHARE an entry recipe need an entry here — service LXCs are
# identified by their own pve/lxc-<name>.rb recipe, not by this table.

darwin = node[:platform] == "darwin"

# --- setup paths / user / group -------------------------------------------
# darwin: group "staff" / system_group "wheel"; linux & LXC: `id -gn` / "root".
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: ENV["USER"],
    group: darwin ? "staff" : `id -gn`.strip,
    system_user: "root",
    system_group: darwin ? "wheel" : "root",
  },
)

# --- homebrew facts (set on EVERY platform; nil on non-darwin) -------------
# Set uniformly so the ~11 cookbooks that read node[:homebrew][:prefix] are
# never nil-prone on a missing key — on Linux the value is simply nil and the
# reads sit behind their own platform guards. M1/M2 Macs default to
# /opt/homebrew; Intel to /opt/brew (Homebrew install.sh L30-32).
machine = darwin ? run_command("uname -m").stdout.strip : nil
node.reverse_merge!(
  homebrew: {
    prefix: darwin ? (machine == "arm64" ? "/opt/homebrew" : "/opt/brew") : nil,
    machine: machine,
  },
)

# --- host identity (offline) ----------------------------------------------
# Match rule mirrors cookbooks/ssh-keys/default.rb: a host matches a FLEET
# entry when (hostname_override || key) OR any alias, downcased, equals the
# live `hostname -s`. `hostname_override` covers Macs whose factory
# serial-format short hostname is unrelated to the human label (air).
fleet = {
  "pro" => {},
  "air" => { "hostname_override" => "xmhtm6qvqx" }, # MacBook Air factory serial
  "neo" => { "aliases" => ["ohnos-macbook"] },      # ohnos-macbook OS hostname
}

current_hostname = run_command("hostname -s").stdout.strip.downcase
label, _spec = fleet.find do |key, spec|
  candidates = [spec["hostname_override"] || key, *(spec["aliases"] || [])]
  candidates.any? { |c| c.downcase == current_hostname }
end

node.reverse_merge!(
  profile: {
    label: label,             # "pro" / "air" / "neo"; nil if not a shared-entry host
    hostname: current_hostname,
  },
)
