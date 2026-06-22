# frozen_string_literal: true
#
# self-heal-observer (Layer 1) — deployed to the monitoring LXC (CT 111).
# A read-only bash poller (NOT a detector, NOT a classifier): it reads the
# alert state Kibana already writes to the alerts-as-data ES indices, dedups
# against the existing `self-heal-state` index, and records NEW/RESOLVED
# transitions there. It does NOT notify — notification is a downstream loop
# (self-heal-create on pro-dev syncs this state to GitHub issues). It emits
# Prometheus textfile metrics for its own liveness.
#
# Why this exists: Kibana runs ~38 alerting rules but their only action is the
# `.server-log` connector (journal, unread) — Kibana notification connectors
# are a paid feature. So firing state lands in ES indices that nobody watches
# (a `Process down: roon` alert sat active+unnoticed for 21+ days). This
# observer makes that state machine-readable; the pro-dev loops turn it into
# GitHub issues (email notification + work log) and fixes. See
# ~/self-heal-observability-loop-design.md (Layer 1) and
# docs/self-heal-github-issues-plan.md.
#
# Cron-driven (every 5 min, +2 offset from the auto-mitamae orchestrator on the
# same host) with its own flock — mirrors cookbooks/auto-mitamae-orchestrator.
#
# Linux only — the monitoring LXC is Debian 13. macOS hosts never run this.

return if node[:platform] == "darwin"

# aws is also installed by auto-mitamae-orchestrator on this same recipe;
# include_recipe dedups, so this is a safe no-op there but keeps the cookbook
# self-contained (jq/curl/flock are added by the bootstrap-deps execute below).
include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys (per
# CLAUDE.md "Auth-check gate must match the cookbook's actual invocation
# profile"). The runtime script uses these for the elastic-password SSM read.
ssh_keys_config = JSON.parse(
  File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")),
)
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

OBSERVER_BIN  = "/usr/local/bin/self-heal-observer.sh"
CRON_FILE     = "/etc/cron.d/self-heal-observer"
LOG_FILE      = "/var/log/self-heal-observer.log"
ENV_FILE      = "/etc/self-heal/observer.env"
staging_dir   = "#{node[:setup][:root]}/self-heal-observer"

# Debian 13 minimal LXC bootstrap deps (per CLAUDE.md "Debian 13 Minimal LXC").
# jq + curl drive the ES queries; ca-certificates for the https ES fetch;
# util-linux (flock) is base but listed for clarity.
execute "self-heal-observer: install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y jq curl ca-certificates util-linux"
  not_if "dpkg -s jq curl ca-certificates util-linux >/dev/null 2>&1"
end

# Defensive directories (per CLAUDE.md "Defensive directory resource" rule).
directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Sibling-of-node-exporter defensive dir (lxc-core owns it; redeclare so
# include order doesn't matter — the observer writes its .prom here).
directory "/var/lib/node_exporter" do
  owner "root"
  group "root"
  mode "0755"
end

directory "/var/lib/node_exporter/textfile" do
  owner "root"
  group "root"
  mode "0755"
end

# /var/lib/self-heal holds the DISABLED kill-switch sentinel; /etc/self-heal
# holds observer.env. CT 111 mitamae runs as root, so owner "root" is a no-op.
directory "/var/lib/self-heal" do
  owner "root"
  group "root"
  mode "0755"
end

directory "/etc/self-heal" do
  owner "root"
  group "root"
  mode "0755"
end

# observer.env — bash-sourceable (the cron-invoked script `.`-sources it).
# These are the runtime contract.
observer_env = <<~ENV
  # Managed by cookbooks/self-heal-observer. Do not edit by hand.
  SELF_HEAL_ES_HOSTS="https://es-0.home.local:9200 https://es-1.home.local:9200 https://es-2.home.local:9200"
  SELF_HEAL_ES_CA="/etc/elastic-agent/certs/ca.crt"
  SELF_HEAL_ELASTIC_PW_SSM="/monitoring/elastic/elastic-password"
  SELF_HEAL_AWS_PROFILE="#{aws_profile}"
  SELF_HEAL_AWS_REGION="#{aws_region}"
  SELF_HEAL_STATE_INDEX="self-heal-state"
  SELF_HEAL_ALERT_INDICES=".alerts-observability.uptime.alerts-default,.alerts-stack.alerts-default"
  SELF_HEAL_TEXTFILE="/var/lib/node_exporter/textfile/self-heal-observer.prom"
  SELF_HEAL_DISABLED_SENTINEL="/var/lib/self-heal/DISABLED"
  SELF_HEAL_PW_CACHE="/run/self-heal/elastic-pw.cache"
  SELF_HEAL_PW_CACHE_TTL="1800"
ENV

file ENV_FILE do
  action :create
  owner "root"
  group "root"
  mode "0644"
  content observer_env
end

# Stage the driver under setup_root, then install with explicit perms
# (mirrors auto-mitamae-orchestrator's stage-then-install pattern).
remote_file "#{staging_dir}/self-heal-observer.sh" do
  source "files/self-heal-observer.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0755"
end

execute "install self-heal-observer.sh to #{OBSERVER_BIN}" do
  command "sudo install -m 0755 -o root -g root " \
          "#{staging_dir}/self-heal-observer.sh #{OBSERVER_BIN}"
  not_if "diff -q #{staging_dir}/self-heal-observer.sh #{OBSERVER_BIN} 2>/dev/null"
end

# cron — every 5 min at minute 2,7,12,... (+2 offset from the orchestrator's
# */5 at minute 0 so the two SSM-fetching cron bodies don't collide). flock -n
# makes overlapping cycles exit cleanly; `timeout 120` hard-caps a hung cycle.
cron_content = <<~CRON
  # Auto-generated by cookbooks/self-heal-observer. Do not edit.
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  MAILTO=""

  2-59/5 * * * *  root  timeout 120 flock -n /var/lock/self-heal-observer.lock #{OBSERVER_BIN} --once >> #{LOG_FILE} 2>&1
CRON

file CRON_FILE do
  action :create
  owner "root"
  group "root"
  mode "0644"
  content cron_content
end

# Pre-create the log file so a sysadmin tailing it before first run sees no
# "no such file" noise (cron's append would create it 0600 root:root anyway).
file LOG_FILE do
  action :create
  owner "root"
  group "root"
  mode "0644"
  not_if "test -f #{LOG_FILE}"
end
