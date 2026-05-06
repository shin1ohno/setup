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

%w[node-exporter-full.json auto-mitamae-fleet.json].each do |dash|
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
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d"
  user user
  action :nothing
  # Skip when .env was not generated (SSM auth absent / non-interactive
  # bootstrap). Restart with empty admin password would leave Grafana
  # unmanageable. Same guard as cookbooks/cognee.
  only_if "test -f #{env_output_path}"
end
