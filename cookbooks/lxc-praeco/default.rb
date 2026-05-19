# frozen_string_literal: true
#
# lxc-praeco (CT 117): PoC of praeco (Vue.js GUI) + ElastAlert 2 server
# for ES-backed alert rule authoring. Standalone — NOT a Kibana plugin.
#
# Stack:
#   - praecoapp/elastalert-server:20260324 (Node.js server + ElastAlert 2)
#       Internal :3030, talks to ES cluster over HTTPS as user
#       `elastalert_writer` (role added in lxc-elasticsearch cookbook).
#   - praecoapp/praeco:1.8.25 (Vue.js SPA on nginx)
#       LAN-exposed :8080, talks to elastalert-server via compose net.
#
# State on host bind-mounts under /data/praeco/{rules,rule_templates,
# server_data} — rules are created by praeco UI via the elastalert-server
# REST API and must survive container recreate.
#
# Phase 3b retro exception: docker-compose is justified here because
# praeco only ships as Docker images (no native install path) and the
# stack is genuinely multi-container (2 services). See
# docs/adr/0005-rtx-logs-loki-to-elasticsearch.md and ~/.claude/rules/
# pve-lxc.md "Design gate: Docker-in-LXC vs apt+systemd".

return if node[:platform] == "darwin"

include_cookbook "docker-engine"
include_cookbook "awscli"

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user       = node[:setup][:user]
group      = node[:setup][:group]
deploy_dir = "#{node[:setup][:home]}/deploy/praeco"
state_dir  = "/data/praeco"

# Defensive directories.
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/lxc-praeco" do
  owner user
  group group
  mode "755"
end

files_dir = "#{node[:setup][:root]}/lxc-praeco/files"
directory files_dir do
  owner user
  group group
  mode "755"
end

generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

# /etc/hosts — DNS-independent startup so the container can resolve
# es-{0,1,2}.home.local without the LAN DNS being up. Mirrors
# lxc-apm-server pattern.
[
  ["192.168.1.77", "es-0.home.local es-0"],
  ["192.168.1.78", "es-1.home.local es-1"],
  ["192.168.1.79", "es-2.home.local es-2"],
  ["192.168.1.80", "kibana.home.local kibana"],
  ["192.168.1.81", "apm-server.home.local apm-server"],
  ["192.168.1.82", "praeco.home.local praeco"],
].each do |ip, hostnames|
  execute "ensure /etc/hosts: #{hostnames.split.first}" do
    command "echo '#{ip} #{hostnames}' >> /etc/hosts"
    not_if "grep -qE '^#{Regexp.escape(ip)}[[:space:]]' /etc/hosts"
  end
end

# Deploy directory + subdirs.
directory deploy_dir do
  owner user
  group group
  mode "755"
end

%w[config certs].each do |sub|
  directory "#{deploy_dir}/#{sub}" do
    owner user
    group group
    mode "755"
  end
end

# State directories — bind-mounted into the elastalert-server container.
# praecoapp/elastalert-server's upstream Dockerfile runs the node process
# as UID 1000 (`node` user). Set ownership to 1000:1000 inside the
# container so writes succeed (per ~/.claude/rules/docker-compose.md
# "Container state path audit when user: is non-root"). On unprivileged
# LXC, in-container UID 1000 maps to host UID 101000; mitamae runs
# inside the container namespace so addressing UID 1000 directly works.
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

%w[rules rule_templates server_data].each do |sub|
  directory "#{state_dir}/#{sub}" do
    owner "1000"
    group "1000"
    mode "755"
  end
end

# docker-compose.yml + elastalert-server config json.
remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart praeco]"
end

remote_file "#{deploy_dir}/config/elastalert-server.json" do
  source "files/elastalert-server-config.json"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart praeco]"
end

# praeco's bundled nginx reverse-proxy config — extracted from
# /tmp/nginx/praeco/nginx_config/default.conf in the praecoapp/praeco
# image. The image's entrypoint does NOT auto-install it, so without
# this bind-mount the SPA's /api/* calls hit the Debian nginx default
# and return 404. Mounted over /etc/nginx/sites-enabled/default in the
# praeco service (see docker-compose.yml).
remote_file "#{deploy_dir}/config/praeco-nginx.conf" do
  source "files/praeco-nginx.conf"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart praeco]"
end

# ElastAlert config template — placeholder @@ELASTALERT_PASSWORD@@ is
# sed-substituted at converge time after .env is generated (mirrors
# lxc-monitoring snmp.yml pattern; avoids env-var interpolation
# inconsistency across ElastAlert 2 config parsers).
elastalert_tmpl_path = "#{files_dir}/elastalert-config.yaml.tmpl"
elastalert_yml_path  = "#{deploy_dir}/config/elastalert.yaml"

remote_file elastalert_tmpl_path do
  source "files/elastalert-config.yaml.tmpl"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[render elastalert.yaml]"
end

# SSM-gated .env (ELASTALERT_PASSWORD) + CA cert. Single auth gate —
# both fetches need the same SSM access.
env_temp_path   = "#{generated_dir}/praeco.env"
env_output_path = "#{deploy_dir}/.env"
ca_cert_path    = "#{deploy_dir}/certs/ca.crt"
ca_staging_dir  = "#{generated_dir}/praeco-certs"

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
fetch_ca_script     = File.join(File.dirname(__FILE__), "files", "fetch_ca.sh")

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/elastalert-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/elastalert-password + /monitoring/elastic/ca/cert in " \
                "#{aws_region}. On a fresh machine: aws configure --profile #{aws_profile}. " \
                "Then press Enter.",
  # Content-aware skip — both .env (with ELASTALERT_PASSWORD) and
  # ca.crt must exist for the gate to be considered closed.
  skip_if: -> {
    File.exist?(env_output_path) &&
      File.read(env_output_path).include?("ELASTALERT_PASSWORD=") &&
      File.exist?(ca_cert_path)
  },
) do
  execute "generate praeco .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user user
  end

  execute "fetch praeco ES CA cert" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{fetch_ca_script} #{ca_staging_dir}"
    user user
  end
end

# Install .env + ca.crt at converge time. only_if guards make these no-ops
# when the auth gate skipped (existing .env / ca.crt remain in place).
remote_file env_output_path do
  source env_temp_path
  owner user
  group group
  mode "0600"
  only_if "test -f #{env_temp_path}"
  notifies :run, "execute[render elastalert.yaml]"
  notifies :run, "execute[restart praeco]"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

execute "install praeco CA cert" do
  command "install -m 0644 -o root -g root #{ca_staging_dir}/ca.crt #{ca_cert_path}"
  only_if "test -f #{ca_staging_dir}/ca.crt"
  not_if "test -f #{ca_cert_path} && " \
         "diff -q #{ca_staging_dir}/ca.crt #{ca_cert_path} >/dev/null 2>&1"
  notifies :run, "execute[restart praeco]"
end

execute "delete praeco CA staging dir" do
  command "rm -rf #{ca_staging_dir}"
  only_if "test -d #{ca_staging_dir} && test -f #{ca_cert_path}"
end

# Render elastalert.yaml from template by substituting
# @@ELASTALERT_PASSWORD@@. Action :nothing — fires from .env or template
# remote_file notifies. ensure-exists fallback below covers fresh boots
# where both inputs exist but the rendered file is absent.
execute "render elastalert.yaml" do
  command <<~SH.strip
    set -euo pipefail
    . #{env_output_path}
    sed "s|@@ELASTALERT_PASSWORD@@|${ELASTALERT_PASSWORD}|g" \
      #{elastalert_tmpl_path} > #{elastalert_yml_path}.new
    mv #{elastalert_yml_path}.new #{elastalert_yml_path}
    chmod 644 #{elastalert_yml_path}
  SH
  user user
  action :nothing
  notifies :run, "execute[restart praeco]"
  only_if "test -f #{env_output_path} && test -f #{elastalert_tmpl_path}"
end

execute "ensure elastalert.yaml exists" do
  command <<~SH.strip
    set -euo pipefail
    . #{env_output_path}
    sed "s|@@ELASTALERT_PASSWORD@@|${ELASTALERT_PASSWORD}|g" \
      #{elastalert_tmpl_path} > #{elastalert_yml_path}.new
    mv #{elastalert_yml_path}.new #{elastalert_yml_path}
    chmod 644 #{elastalert_yml_path}
  SH
  user user
  only_if "test -f #{env_output_path} && test -f #{elastalert_tmpl_path} && ! test -f #{elastalert_yml_path}"
end

# Bring containers up. DOCKER_BUILDKIT=0 per CLAUDE.md "Docker Build in
# Unprivileged PVE LXC" rule (nesting=true + classic builder).
compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = "praeco"

execute "ensure praeco running" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d"
  user user
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{elastalert_yml_path} || exit 1;
    test -f #{ca_cert_path} || exit 1;
    expected=$(docker compose -f #{compose_path} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH
end

execute "restart praeco" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --force-recreate"
  user user
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{elastalert_yml_path} && test -f #{ca_cert_path}"
end
