# frozen_string_literal: true
#
# lxc-kibana (CT 115): Kibana 8.x — log analytics UI for the 3-node ES
# cluster (es-0/1/2). Single instance.
#
# Stack:
#   - docker.elastic.co/kibana/kibana:8.16.0  :5601 (LAN)
#
# State volume: /data/kibana/{data,certs} on rpool (50 GB, ADR §構成).
#   No bind-mount UID gymnastics needed (rpool is on the LXC's own
#   storage, no PVE mp0 entry).
#
# Phase 3b ships ES on HTTP plain. kibana.yml uses http:// URLs to
# the cluster. Phase 7-tls migrates to https:// + CA cert verification;
# the CA cert is staged at /data/kibana/certs/ca.crt already in this
# phase so the cutover only changes the yaml.
#
# Adversarial findings folded in:
#   #6  .env mode 0600 root:root
#   #7  3 Kibana encryption keys (SO / reporting / security) — all 32-char
#       hex from SSM, required to survive Kibana restarts
#   #12 ATOMIC sequencing with ES bootstrap: lxc-elasticsearch's
#       bootstrap-init.sh resets kibana_system password to match SSM
#       BEFORE this cookbook reads the same SSM value into kibana.yml.
#       The cluster apply order in adr0005 (es-0 → es-1 → es-2 → kibana)
#       enforces this implicitly.

return if node[:platform] == "darwin"

include_cookbook "docker-engine"
include_cookbook "awscli"

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user       = node[:setup][:user]
group      = node[:setup][:group]
deploy_dir = "#{node[:setup][:home]}/deploy/kibana"
state_dir  = "/data/kibana"

# Defensive directories.
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/lxc-kibana" do
  owner user
  group group
  mode "755"
end

directory deploy_dir do
  owner user
  group group
  mode "755"
end

# State volume — Kibana image runs as UID 1000 (kibana).
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

%w[data certs].each do |sub|
  directory "#{state_dir}/#{sub}" do
    owner "1000"
    group "1000"
    mode "755"
  end
end

# === compose + config ===

remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart kibana]"
end

# kibana.yml is bind-mounted as-is (env vars expand at container start;
# no sed substitution needed because the yaml already references
# ${KIBANA_PASSWORD} / ${KIBANA_ENC_*_KEY} as Kibana env-style refs).
remote_file "#{deploy_dir}/kibana.yml" do
  source "files/kibana.yml.tmpl"
  owner user
  group group
  mode "0644"
  notifies :run, "execute[restart kibana]"
end

# === SSM-gated env + CA cert generation ===

generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

env_temp_path   = "#{generated_dir}/kibana.env"
env_output_path = "#{deploy_dir}/.env"
generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
fetch_ca_script     = File.join(File.dirname(__FILE__), "files", "fetch_ca.sh")
ca_staging_dir      = "#{generated_dir}/kibana-ca"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/kibana-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate kibana .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user user
  end

  execute "fetch kibana CA cert" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{fetch_ca_script} #{ca_staging_dir}"
    user user
  end
end

remote_file env_output_path do
  source env_temp_path
  owner user
  group group
  mode "0600"
  notifies :run, "execute[restart kibana]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# Install CA cert (mode 0644, owner UID 1000 to match container user).
execute "install kibana CA cert" do
  command "sudo install -m 0644 -o 1000 -g 1000 " \
          "#{ca_staging_dir}/ca.crt #{state_dir}/certs/ca.crt"
  only_if "test -f #{ca_staging_dir}/ca.crt"
  not_if "test -f #{state_dir}/certs/ca.crt && " \
         "diff -q #{ca_staging_dir}/ca.crt #{state_dir}/certs/ca.crt 2>/dev/null"
  notifies :run, "execute[restart kibana]"
end

execute "delete kibana CA staging" do
  command "rm -rf #{ca_staging_dir}"
  only_if "test -d #{ca_staging_dir} && test -f #{state_dir}/certs/ca.crt"
end

# === docker compose orchestration ===

compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = File.basename(deploy_dir)

execute "ensure kibana running" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d"
  user user
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{deploy_dir}/kibana.yml || exit 1;
    expected=$(docker compose -f #{compose_path} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH
end

execute "restart kibana" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --force-recreate"
  user user
  action :nothing
  only_if "test -f #{env_output_path}"
end
