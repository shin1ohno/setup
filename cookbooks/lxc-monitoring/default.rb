# frozen_string_literal: true
#
# lxc-monitoring (CT 111): Prometheus + Grafana stack for fleet observability.
#
# Stack:
#   - prom/prometheus:v2.55.1     :9090 (loopback-only inside the LXC)
#   - grafana/grafana:11.6.14     :3000 (LAN, LAN-only via firewall)
#
# State volumes (host paths bind-mounted into the containers):
#   /data/monitoring/prometheus/   TSDB
#   /data/monitoring/grafana/      grafana state (sqlite db, plugins)
#
# Provisioning:
#   - Prometheus datasource auto-loaded from /etc/grafana/provisioning/datasources
#   - Dashboards auto-loaded from /etc/grafana/dashboards
#       (a) Node Exporter Full (community ID 1860) — vendored
#       (b) Auto-mitamae Fleet — Phase 2a minimal, extended in Phase 2b
#
# Phase 2c (out of scope): Tailscale public access via mcp.ohno.be/grafana/
# through mcp-proxy. Phase 2 binds Grafana to the LAN only.
#
# CT 111 also runs node_exporter (cookbooks/node-exporter) as a sibling
# cookbook and self-applies via auto-mitamae-target — both included from
# pve/lxc-monitoring.rb.

return if node[:platform] == "darwin"

include_cookbook "docker-engine"
include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so the
# require_external_auth check_command and the .env generator both target the
# same IAM principal. Per CLAUDE.md "Auth-check gate must match the cookbook's
# actual invocation profile" — a bare check (no --profile) passes against
# whatever the host's `default` profile happens to be and is therefore a
# false gate when the cookbook actually invokes a named profile.
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "devices.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user = node[:setup][:user]
group = node[:setup][:group]
deploy_dir = "#{node[:setup][:home]}/deploy/monitoring"
state_dir  = "/data/monitoring"

# Defensive: ensure setup_root + per-cookbook subdir exist before any
# remote_file write. Per CLAUDE.md "Defensive directory resource" rule.
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/lxc-monitoring" do
  owner user
  group group
  mode "755"
end

# Deploy directory + Grafana provisioning subdirs.
directory deploy_dir do
  owner user
  group group
  mode "755"
end

%w[grafana grafana/provisioning grafana/provisioning/datasources grafana/provisioning/dashboards grafana/dashboards].each do |sub|
  directory "#{deploy_dir}/#{sub}" do
    owner user
    group group
    mode "755"
  end
end

# State volumes — root-owned (containers mount these). Mode 755 so the
# Prometheus / Grafana containers (uid 65534 / 472 respectively) can write
# to them. The container images create the inner per-service subdirs at
# startup with the right uid.
directory "/data" do
  owner "root"
  group "root"
  mode "755"
end

directory state_dir do
  owner "root"
  group "root"
  mode "755"
end

# Per-service state subdirs. Each container runs as its own non-root UID
# and writes sqlite WAL / lock / journal files INTO the parent dir (not
# just inside subdirs the container creates) — so the dir itself must be
# writable by the container's UID.
#
# Grafana 11.x → uid=472(grafana). Without uid 472 ownership, grafana.db
# opens read-only, sqlite raises "attempt to write a readonly database",
# and login fails with "Internal Server Error". Per CLAUDE.md
# `infrastructure.md` "Container state path audit when `user:` is non-root".
#
# Prometheus 2.x → uid=65534(nobody). TSDB writes (chunks_head/, wal/,
# lock, queries.active) all happen inside /prometheus.
#
# Set per-service explicitly with String UIDs (Integer raises
# InvalidTypeError per `ruby.md` "owner/group must be String").
state_dir_owners = {
  "prometheus" => "65534", # nobody (prom/prometheus standard)
  "grafana"    => "472",   # grafana (grafana/grafana standard)
}
state_dir_owners.each do |sub, uid|
  directory "#{state_dir}/#{sub}" do
    owner uid
    group uid
    mode "755"
  end
end

# Compose + scrape config + provisioning files.
remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/prometheus.yml" do
  source "files/prometheus.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/grafana/provisioning/datasources/prometheus.yml" do
  source "files/grafana/provisioning/datasources/prometheus.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

remote_file "#{deploy_dir}/grafana/provisioning/dashboards/dashboards.yml" do
  source "files/grafana/provisioning/dashboards/dashboards.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

%w[node-exporter-full.json auto-mitamae-fleet.json proxmox-via-prometheus.json mcp-fleet-health.json].each do |dash|
  remote_file "#{deploy_dir}/grafana/dashboards/#{dash}" do
    source "files/grafana/dashboards/#{dash}"
    owner user
    group group
    mode "0644"
    notifies :run, "execute[restart monitoring]"
  end
end

# Generate .env from SSM (Grafana admin password). Mirror cognee pattern:
# stage in setup_root/generated, then move to deploy_dir/.env. require_external_auth
# pauses on a fresh host until AWS auth is configured (or skip in non-TTY).
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
env_temp_path = "#{generated_dir}/monitoring.env"
env_output_path = "#{deploy_dir}/.env"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/grafana-admin-password",
  check_command: "aws ssm get-parameter --name /monitoring/grafana-admin-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/grafana-admin-password in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate monitoring .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user user
  end
end

# Place .env at converge time (only_if test -f), then clean up the staged
# copy. Same compile-vs-converge guard pattern as cookbooks/cognee.
remote_file env_output_path do
  source env_temp_path
  owner user
  group group
  mode "0600"
  notifies :run, "execute[restart monitoring]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = File.basename(deploy_dir)

# Bring containers up. DOCKER_BUILDKIT=0 because the unprivileged LXC's
# nesting=true setting + classic builder is the proven combination per
# CLAUDE.md "Docker Build in Unprivileged PVE LXC" rule. No subdir-context
# Dockerfiles here (only image pulls), so classic builder is sufficient.
execute "ensure monitoring running" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d"
  user user
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    expected=$(docker compose -f #{compose_path} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH
end

execute "restart monitoring" do
  # --force-recreate forces re-creation even when image + compose spec are
  # unchanged, picking up bind-mounted config edits (prometheus.yml,
  # grafana provisioning yaml, dashboards/*.json) that bare `up -d`
  # silently skips on already-running containers. Discovered when adding
  # honor_labels to prometheus.yml in PR #154 — the notify fired but the
  # bare `up -d` was a no-op, so the new label semantics never reached
  # the running prometheus container until manual SIGHUP. Same fix shape
  # as PR #158 for the other 6 cookbooks; lxc-monitoring was excluded
  # there to avoid an apparent (but ultimately illusory) merge conflict.
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --force-recreate"
  user user
  action :nothing
  # Skip when .env was not generated (SSM auth absent / non-interactive
  # bootstrap). Restart with empty admin password would leave Grafana
  # unmanageable. Same guard as cookbooks/cognee.
  only_if "test -f #{env_output_path}"
end

# === MCP Fleet Health Monitoring ===
#
# Three layers of MCP observability stacked on the existing fleet stack:
#
#   1. blackbox_exporter (HTTP/TCP probes) — sibling docker-compose service
#      defined in docker-compose.yml. Targets defined in prometheus.yml's
#      `mcp-blackbox-{external,oidc,oauth-meta,internal}` jobs.
#
#   2. alerts/mcp.yml (Prometheus rules) — bind-mounted into the prometheus
#      container at /etc/prometheus/alerts/. Loaded via rule_files in
#      prometheus.yml.
#
#   3. mcp-probe.{service,timer} + /usr/local/bin/mcp-probe.py — system
#      systemd timer that runs the MCP-protocol prober (OAuth ->
#      initialize -> tools/list) once per minute. Output lands in the
#      node_exporter textfile collector dir, picked up by the existing
#      `node-monitoring` scrape job.
#
# All three are gated on the same SSM auth as the rest of the cookbook
# (require_external_auth pattern). The MCP-protocol prober additionally
# depends on the Hydra `monitoring-prober` client being registered first
# (see cookbooks/hydra-server/default.rb); the env-fetch step skips
# gracefully when SSM doesn't have the credentials yet, and the timer
# enable step waits for /etc/mcp-probe/probe.env to exist.

# Layer 1 + 2: bind-mounted configs.
remote_file "#{deploy_dir}/blackbox.yml" do
  source "files/blackbox.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

directory "#{deploy_dir}/alerts" do
  owner user
  group group
  mode "755"
end

remote_file "#{deploy_dir}/alerts/mcp.yml" do
  source "files/alerts/mcp.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart monitoring]"
end

# Layer 3: MCP-protocol prober.

mcp_probe_staging = "#{node[:setup][:root]}/lxc-monitoring/mcp-probe"
directory mcp_probe_staging do
  owner user
  group group
  mode "755"
end

remote_file "#{mcp_probe_staging}/probe.py" do
  source "files/mcp-probe/probe.py"
  owner user
  group group
  mode "0755"
end

remote_file "#{mcp_probe_staging}/fetch-secrets.sh" do
  source "files/mcp-probe/fetch-secrets.sh"
  owner user
  group group
  mode "0755"
end

%w[mcp-probe.service mcp-probe.timer].each do |unit|
  remote_file "#{mcp_probe_staging}/#{unit}" do
    source "files/systemd/#{unit}"
    owner user
    group group
    mode "0644"
  end
end

# Install the python script into a system PATH location.
execute "install /usr/local/bin/mcp-probe.py" do
  command "sudo install -m 755 -o root -g root " \
          "#{mcp_probe_staging}/probe.py /usr/local/bin/mcp-probe.py"
  not_if "diff -q #{mcp_probe_staging}/probe.py /usr/local/bin/mcp-probe.py 2>/dev/null"
  notifies :run, "execute[restart mcp-probe.timer]"
end

# /etc/mcp-probe/ holds the EnvironmentFile consumed by mcp-probe.service.
execute "ensure /etc/mcp-probe directory" do
  command "sudo install -d -m 755 -o root -g root /etc/mcp-probe"
  not_if "test -d /etc/mcp-probe"
end

# /var/lib/node_exporter/textfile_collector — node_exporter scrapes this.
# The node-exporter cookbook already creates it on the monitoring LXC;
# this is a defensive ensure-exists that's a no-op when present.
execute "ensure node_exporter textfile collector directory" do
  command "sudo install -d -m 755 -o root -g root " \
          "/var/lib/node_exporter/textfile_collector"
  not_if "test -d /var/lib/node_exporter/textfile_collector"
end

# Install systemd unit + timer.
%w[mcp-probe.service mcp-probe.timer].each do |unit|
  execute "install /etc/systemd/system/#{unit}" do
    command "sudo install -m 644 -o root -g root " \
            "#{mcp_probe_staging}/#{unit} /etc/systemd/system/#{unit}"
    not_if "diff -q #{mcp_probe_staging}/#{unit} /etc/systemd/system/#{unit} 2>/dev/null"
    notifies :run, "execute[mcp-probe systemctl daemon-reload]"
  end
end

execute "mcp-probe systemctl daemon-reload" do
  command "sudo systemctl daemon-reload"
  action :nothing
end

# Generate /etc/mcp-probe/probe.env from SSM. Same compile-vs-converge
# pattern as the .env block above (CLAUDE.md ruby.md "Mitamae evaluation
# model — top-level Ruby is compile-time"): stage in setup_root/generated,
# then install with `only_if test -f` so the converge-time presence check
# matches the converge-time creation.
probe_env_temp   = "#{generated_dir}/mcp-probe.env"
probe_env_system = "/etc/mcp-probe/probe.env"
probe_env_script = "#{mcp_probe_staging}/fetch-secrets.sh"

require_external_auth(
  tool_name: "AWS CLI for /monitoring/mcp-prober-{client-id,client-secret} SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/mcp-prober-client-id " \
                 "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1",
  instructions: "Run cookbooks/hydra-server first (on the Hydra LXC, CT 106) — " \
                "it registers the monitoring-prober Hydra client and writes " \
                "client-id/secret to SSM. Then this cookbook can fetch them.",
  skip_if: -> { File.exist?(probe_env_system) },
) do
  execute "generate mcp-probe env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{probe_env_script} #{probe_env_temp}"
    user user
  end
end

# Install at converge time when the temp env was successfully generated.
execute "install /etc/mcp-probe/probe.env" do
  command "sudo install -m 600 -o root -g root #{probe_env_temp} #{probe_env_system}"
  only_if "test -f #{probe_env_temp}"
  notifies :run, "execute[restart mcp-probe.timer]"
end

execute "delete mcp-probe staging env" do
  command "rm -f #{probe_env_temp}"
  only_if "test -f #{probe_env_temp}"
end

# Enable the timer once the env file is in place. The unit's
# EnvironmentFile= directive blocks startup if probe.env is absent,
# so gating the enable on that file presence avoids start failures
# on a fresh host where SSM auth hasn't been configured yet.
execute "enable mcp-probe.timer" do
  command "sudo systemctl enable --now mcp-probe.timer"
  only_if "test -f #{probe_env_system}"
  not_if "systemctl is-enabled --quiet mcp-probe.timer 2>/dev/null && " \
         "systemctl is-active --quiet mcp-probe.timer 2>/dev/null"
end

execute "restart mcp-probe.timer" do
  command "sudo systemctl restart mcp-probe.timer"
  action :nothing
  # Skip when systemd unit was not yet installed (e.g. fresh host where
  # the install step is still pending or SSM-gated bootstrap is incomplete).
  only_if "systemctl list-unit-files mcp-probe.timer 2>/dev/null | grep -q mcp-probe.timer"
end
