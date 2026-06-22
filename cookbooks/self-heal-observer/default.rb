# frozen_string_literal: true
#
# self-heal-observer (Phase 1): a read-only Elasticsearch observability loop
# deployed to the monitoring LXC (CT 111). The Rust binary
# (/usr/local/bin/self-heal-observer --once) polls the ES cluster, derives
# per-(signal, host) issue state, persists it to the `self-heal-state` index,
# and emits Prometheus textfile metrics into node_exporter's textfile dir.
#
# Read-only: the observer never mutates fleet state. It only OBSERVES ES and
# WRITES its own self-heal-state index + a .prom textfile. Escalation is
# surfaced via Prometheus alerts (cookbooks/lxc-monitoring/files/alerts/
# self-heal.yml) and a Kibana dashboard, not via automated remediation.
#
# Timer-driven oneshot (every 5 min, +2 offset from the auto-mitamae
# orchestrator on the same host) so the two cron/timer cycles don't collide.
#
# Linux only — the binary is a linux-x86_64 build and the monitoring LXC is
# Debian 13. macOS hosts never run this cookbook.

return if node[:platform] == "darwin"

SELF_HEAL_OBSERVER_VERSION = "0.1.0"

# Filled at integration time from the release asset's .sha256 sidecar. The
# GitHub release shin1ohno/self-heal-observer v#{VERSION} does NOT exist yet.
# While this stays the placeholder the binary-download + systemd activation
# below are GATED OFF (release_available == false): the cookbook converges to
# a safe no-op (state/config dirs + observer.env only), so a fresh
# auto-mitamae cycle on CT 111 never fails on a curl-404 or a missing-binary
# `systemctl start`. The integration PR (which cuts the release) replaces this
# SHA; release_available then flips true and the full download/verify/install
# + timer activation converge cleanly and stay a no-op thereafter.
SELF_HEAL_OBSERVER_PLACEHOLDER_SHA = "PLACEHOLDER_FILLED_AT_RELEASE"
SELF_HEAL_OBSERVER_SHA256          = "PLACEHOLDER_FILLED_AT_RELEASE"

# Gating on a compile-time CONSTANT comparison is safe — unlike the
# `if File.exist?(...)` anti-pattern (~/.claude/rules/ruby.md "Mitamae
# evaluation model"), this branch has no converge-time side-effect dependency,
# so the compile-phase value is the value that matters.
release_available = SELF_HEAL_OBSERVER_SHA256 != SELF_HEAL_OBSERVER_PLACEHOLDER_SHA

SELF_HEAL_OBSERVER_BINARY  = "/usr/local/bin/self-heal-observer"
SELF_HEAL_OBSERVER_REPO    = "shin1ohno/self-heal-observer"
SELF_HEAL_TEXTFILE_DIR     = "/var/lib/node_exporter/textfile"

archive_name = "self-heal-observer-#{SELF_HEAL_OBSERVER_VERSION}-linux-x86_64.tar.gz"
staging_dir  = "#{node[:setup][:root]}/self-heal-observer"
archive_path = "#{staging_dir}/#{archive_name}"
archive_url  = "https://github.com/#{SELF_HEAL_OBSERVER_REPO}/releases/download/" \
               "v#{SELF_HEAL_OBSERVER_VERSION}/#{archive_name}"

# Debian 13 minimal LXC bootstrap deps (per CLAUDE.md "Debian 13 Minimal LXC
# — Mandatory Bootstrap Packages"). curl + tar drive the download/extract;
# ca-certificates is needed for the https GitHub fetch.
execute "self-heal-observer: install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y curl tar ca-certificates"
  not_if "dpkg -s curl tar ca-certificates >/dev/null 2>&1"
end

# Defensive: setup_root may not exist yet on a fresh bootstrap (per CLAUDE.md
# "Defensive directory resource" rule), and the staging subdir is REQUIRED
# before the remote_file/curl drops land under it.
directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# State + config dirs for the binary. /var/lib/self-heal holds the DISABLED
# sentinel; /etc/self-heal holds observer.env. CT 111 mitamae runs as root,
# so owner "root" chown is a no-op (no EPERM).
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

# Defensive: node-exporter (via lxc-core) owns this dir, but redeclare so
# include order doesn't matter — the observer writes its .prom here.
directory SELF_HEAL_TEXTFILE_DIR do
  owner "root"
  group "root"
  mode "0755"
end

# --- binary download + sha256 verify + install -----------------------------
# Mirrors cookbooks/node-exporter. Idempotency: skip the whole pipeline when
# the on-disk binary already reports the target version. GATED on
# release_available so an ahead-of-binary apply (placeholder SHA) is a no-op,
# not a curl-404 converge failure.
if release_available
  binary_version_check = "test -x #{SELF_HEAL_OBSERVER_BINARY} && " \
                         "#{SELF_HEAL_OBSERVER_BINARY} --version 2>/dev/null | " \
                         "grep -q #{SELF_HEAL_OBSERVER_VERSION}"

  execute "download self-heal-observer v#{SELF_HEAL_OBSERVER_VERSION}" do
    command "curl -fsSL -o #{archive_path} #{archive_url}"
    user node[:setup][:user]
    not_if binary_version_check
  end

  execute "verify self-heal-observer sha256" do
    command "echo '#{SELF_HEAL_OBSERVER_SHA256}  #{archive_path}' | shasum -a 256 -c -"
    user node[:setup][:user]
    not_if binary_version_check
  end

  execute "extract + install self-heal-observer binary" do
    command <<~SH
      set -e
      cd #{staging_dir}
      tar -xzf #{archive_name}
      sudo install -m 0755 -o root -g root self-heal-observer #{SELF_HEAL_OBSERVER_BINARY}
      rm -f self-heal-observer
    SH
    user node[:setup][:user]
    not_if binary_version_check
  end
end

# --- observer.env (systemd EnvironmentFile) --------------------------------
# AWS profile/region reuse the ssh-keys bootstrap convention (the binary uses
# them to fetch the elastic password from SSM at runtime). The values below
# are the BINARY CONTRACT — keep in lockstep with the Rust crate's env parsing.
# Written unconditionally (harmless without the binary) so the config is in
# place the moment the release lands.
ssh_keys_config = JSON.parse(
  File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")),
)
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

observer_env = <<~ENV
  # Managed by cookbooks/self-heal-observer. Do not edit by hand.
  SELF_HEAL_ES_HOSTS="https://es-0.home.local:9200 https://es-1.home.local:9200 https://es-2.home.local:9200"
  SELF_HEAL_ES_CA=/etc/elastic-agent/certs/ca.crt
  SELF_HEAL_ELASTIC_PW_SSM=/monitoring/elastic/elastic-password
  SELF_HEAL_AWS_PROFILE=#{aws_profile}
  SELF_HEAL_AWS_REGION=#{aws_region}
  SELF_HEAL_STATE_INDEX=self-heal-state
  SELF_HEAL_ESCALATE_AFTER=3
  SELF_HEAL_RESOLVE_AFTER=3
  SELF_HEAL_FRESH_MAX_S=300
  SELF_HEAL_DECOMMISSIONED_HOSTS=nrt-subnet-router,ip-10-33-131-169
  SELF_HEAL_TEXTFILE=#{SELF_HEAL_TEXTFILE_DIR}/self-heal-observer.prom
  SELF_HEAL_DISABLED_SENTINEL=/var/lib/self-heal/DISABLED
  SELF_HEAL_PW_CACHE=/run/self-heal/elastic-pw.cache
  SELF_HEAL_PW_CACHE_TTL=1800
ENV

file "/etc/self-heal/observer.env" do
  action :create
  owner "root"
  group "root"
  mode "0644"
  content observer_env
end

# --- systemd unit + timer ---------------------------------------------------
# Stage both into the staging dir (so `source "files/..."` resolves to THIS
# cookbook), then install + activate via the systemd_unit helper. The .service
# is oneshot + timer-driven, so `start false` skips an immediate restart; the
# .timer activation enables the timer and starts the companion service once to
# seed the OnUnitInactiveSec deactivation reference.
#
# GATED on release_available: the .timer activation runs `systemctl start
# self-heal-observer.service`, which would invoke the missing binary and fail
# the converge. Ahead of the release we install no units and enable no timer,
# so nothing references the absent binary.
if release_available
  service_staging = "#{staging_dir}/self-heal-observer.service"
  timer_staging   = "#{staging_dir}/self-heal-observer.timer"

  remote_file service_staging do
    source "files/self-heal-observer.service"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

  remote_file timer_staging do
    source "files/self-heal-observer.timer"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

  systemd_unit "self-heal-observer.service" do
    staging_path service_staging
    start false
  end

  systemd_unit "self-heal-observer.timer" do
    staging_path timer_staging
  end
end
