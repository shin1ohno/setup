# frozen_string_literal: true
#
# Single-cookbook test harness. Apply only the cookbook specified by the
# COOKBOOK env var, with the same `node[:setup]` / `node[:homebrew]` init
# that darwin.rb / linux.rb perform. Useful for iterating on one cookbook
# without paying the multi-minute cost of a full platform apply.
#
# Cookbooks that depend on other cookbooks (e.g. elastic-agent uses
# awscli, mise pulls usage) include them transitively via the cookbook's
# own `include_cookbook` calls — no explicit dependency declaration here.
#
# Usage:
#   COOKBOOK=elastic-agent ./bin/mitamae local test-cookbook.rb --dry-run
#   COOKBOOK=mise          ./bin/mitamae local test-cookbook.rb
#
# Platform-aware: replicates darwin.rb's node[:homebrew] block on macOS,
# linux.rb's primary-group resolution on linux. Container guard from
# linux.rb is intentionally NOT replicated — this harness is for ad-hoc
# debugging, not bare-metal-only enforcement.

include_recipe "cookbooks/functions/default"

cookbook_name = ENV["COOKBOOK"].to_s
if cookbook_name.empty?
  raise "Set COOKBOOK=<name> to choose which cookbook to apply " \
        "(e.g. COOKBOOK=elastic-agent ./bin/mitamae local test-cookbook.rb)."
end
# Existence check is intentionally delegated to include_cookbook below;
# it raises a clear "Cookbook <name> is not found" with the resolved
# path. (`__FILE__` / `__dir__` are unavailable in the eval'd recipe
# context, so a local stat would be brittle.)

user = ENV["USER"]

if node[:platform] == "darwin"
  machine = run_command("uname -m").stdout.strip
  node.reverse_merge!(
    setup: {
      home: ENV["HOME"],
      root: "#{ENV["HOME"]}/.setup_shin1ohno",
      user: user,
      group: "staff",
      system_user: "root",
      system_group: "wheel",
    },
    homebrew: {
      prefix: machine == "arm64" ? "/opt/homebrew" : "/opt/brew",
      machine: machine,
    },
  )
else
  group = `id -gn`.strip
  node.reverse_merge!(
    setup: {
      home: ENV["HOME"],
      root: "#{ENV["HOME"]}/.setup_shin1ohno",
      user: user,
      group: group,
      system_user: "root",
      system_group: "root",
    },
  )
end

include_cookbook cookbook_name
