# frozen_string_literal: true
#
# lxc-kibana (CT 115): Kibana 8.x — log analytics UI for the 3-node ES
# cluster (es-0/1/2). Single instance. Native apt + systemd install
# (Phase 3b retro: docker-compose deployment was replaced because of
# structural docker-isms — see ~/.claude/rules/pve-lxc.md "Docker-in-LXC
# vs apt+systemd").
#
# Stack:
#   - Kibana 9.4.2 DEB (apt-mark hold)  :5601 (LAN)
#   - systemd unit kibana.service (DEB-shipped)
#   - /etc/systemd/system/kibana.service.d/override.conf (cookbook-managed)
#
# State: /data/kibana/{data,certs} on rpool (50 GB, ADR §構成). No
# bind-mount UID gymnastics needed (rpool is on the LXC's own storage,
# no PVE mp0 entry).
#
# Phase 3b ships ES on HTTP plain. kibana.yml uses http:// URLs to
# the cluster. Phase 7-tls migrates to https:// + CA cert verification;
# the CA cert is staged at /etc/kibana/certs/ca.crt already in this
# phase so the cutover only changes the yaml.
#
# Adversarial findings folded in:
#   #6  /etc/kibana/kibana-secrets.env mode 0640 root:kibana
#   #7  3 Kibana encryption keys (SO / reporting / security) — all 32-char
#       hex from SSM, required to survive Kibana restarts
#   #12 ATOMIC sequencing with ES bootstrap: lxc-elasticsearch's
#       bootstrap-init.sh resets kibana_system password to match SSM
#       BEFORE this cookbook reads the same SSM value into kibana.yml.
#       The cluster apply order in adr0005 (es-0 → es-1 → es-2 → kibana)
#       enforces this implicitly.
#
# Migration from docker (UC2): operator must `docker compose down` BEFORE
# the first native apply. Data dir survives unchanged. After native
# apply succeeds, the operator may remove ~/deploy/kibana/.

return if node[:platform] == "darwin"

include_cookbook "awscli"

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user      = node[:setup][:user]
group     = node[:setup][:group]
state_dir = "/data/kibana"

# Defensive directories.
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/lxc-kibana" do
  owner user
  group group
  mode "755"
end

files_dir = "#{node[:setup][:root]}/lxc-kibana/files"
directory files_dir do
  owner user
  group group
  mode "755"
end

# === Elastic apt repo registration ===

execute "install elastic apt prerequisites" do
  command "apt-get install -y ca-certificates curl gnupg apt-transport-https"
  not_if {
    %w(ca-certificates curl gnupg apt-transport-https).all? { |pkg|
      run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0
    }
  }
end

execute "add elastic apt key" do
  command <<~SH.strip
    install -d -m 0755 /etc/apt/keyrings && \
      curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
      gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg && \
      chmod a+r /etc/apt/keyrings/elastic.gpg
  SH
  not_if { File.exist?("/etc/apt/keyrings/elastic.gpg") }
end

execute "add elastic apt repo" do
  command "echo 'deb [signed-by=/etc/apt/keyrings/elastic.gpg] " \
          "https://artifacts.elastic.co/packages/9.x/apt stable main' " \
          "> /etc/apt/sources.list.d/elastic-9.x.list"
  not_if "test -f /etc/apt/sources.list.d/elastic-9.x.list && " \
         "grep -q 'artifacts.elastic.co' /etc/apt/sources.list.d/elastic-9.x.list"
  notifies :run, "execute[apt-get update for elastic]", :immediately
end

execute "apt-get update for elastic" do
  command "apt-get update -qq"
  action :nothing
end

# === State volume ===
#
# /data/kibana lives on rpool inside the LXC (no bind-mount). Kibana
# system user is created by the DEB postinst (typically UID 116+ on
# Debian trixie); we chown the data dir to that user after install.
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

directory "#{state_dir}/data" do
  mode "755"
end

# === Install Kibana DEB ===

execute "install kibana 9.4.2" do
  command "apt-get install -y kibana=9.4.2"
  not_if "dpkg-query -W -f='${Version}' kibana 2>/dev/null | grep -q '^9.4.2$'"
end

execute "apt-mark hold kibana" do
  command "apt-mark hold kibana"
  not_if "apt-mark showhold | grep -q '^kibana$'"
end

# Re-chown bind-mount data dir to kibana user (created by DEB postinst).
execute "chown #{state_dir}/data to kibana" do
  command "chown -R kibana:kibana #{state_dir}/data"
  only_if "id kibana >/dev/null 2>&1"
  not_if "test \"$(stat -c '%U:%G' #{state_dir}/data)\" = 'kibana:kibana'"
end

# Cert directory under /etc/kibana — Kibana 8.x doesn't enforce the
# Java SecurityManager FilePermission constraint that Elasticsearch does,
# but we keep cert install under /etc/kibana for fleet consistency with
# lxc-elasticsearch and to avoid surprises in Phase 7-tls switchover.
execute "create /etc/kibana/certs directory" do
  command "install -d -m 0750 -o root -g kibana /etc/kibana/certs"
  only_if "id kibana >/dev/null 2>&1"
  not_if "test -d /etc/kibana/certs && " \
         "test \"$(stat -c '%U:%G:%a' /etc/kibana/certs)\" = 'root:kibana:750'"
end

# === kibana.yml ===
#
# kibana.yml supports ${VAR} substitution from environment at startup;
# systemd's EnvironmentFile= exports KIBANA_PASSWORD / KIBANA_ENC_*_KEY
# into Kibana's process environment, so the yaml needs no sed pre-render
# step.
kibana_yml_staging = "#{files_dir}/kibana.yml"
kibana_yml_path    = "/etc/kibana/kibana.yml"

remote_file kibana_yml_staging do
  source "files/kibana.yml.tmpl"
  owner user
  group group
  mode "0644"
end

execute "install kibana.yml" do
  command "install -m 0660 -o root -g kibana #{kibana_yml_staging} #{kibana_yml_path}"
  only_if "id kibana >/dev/null 2>&1"
  not_if "test -f #{kibana_yml_path} && diff -q #{kibana_yml_staging} #{kibana_yml_path} 2>/dev/null"
  notifies :run, "execute[restart kibana]"
end

# === systemd override ===

unit_override_staging = "#{files_dir}/kibana.service.override.conf"
unit_override_dir     = "/etc/systemd/system/kibana.service.d"
unit_override_path    = "#{unit_override_dir}/override.conf"

remote_file unit_override_staging do
  source "files/kibana.service.override.conf"
  owner user
  group group
  mode "0644"
end

execute "create kibana.service.d directory" do
  command "install -d -m 0755 -o root -g root #{unit_override_dir}"
  not_if "test -d #{unit_override_dir}"
end

execute "install kibana systemd override" do
  command "install -m 0644 -o root -g root #{unit_override_staging} #{unit_override_path}"
  not_if "test -f #{unit_override_path} && diff -q #{unit_override_staging} #{unit_override_path} 2>/dev/null"
  notifies :run, "execute[kibana daemon-reload]", :immediately
  notifies :run, "execute[restart kibana]"
end

execute "kibana daemon-reload" do
  command "systemctl daemon-reload"
  action :nothing
end

# === SSM-gated env + CA cert generation ===

generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

env_temp_path   = "#{generated_dir}/kibana.env"
env_output_path = "/etc/kibana/kibana-secrets.env"
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
  # Skip when env file AND CA cert already exist at the new locations.
  skip_if: -> {
    File.exist?(env_output_path) &&
      File.exist?("/etc/kibana/certs/ca.crt")
  },
) do
  execute "generate kibana secrets env" do
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

# Install kibana-secrets.env — mode 0640 root:kibana. systemd
# EnvironmentFile reads bare KEY=VALUE without shell expansion, so
# metacharacter-bearing passwords are passed through literally.
execute "install kibana-secrets.env" do
  command "install -m 0640 -o root -g kibana #{env_temp_path} #{env_output_path}"
  only_if "test -f #{env_temp_path} && id kibana >/dev/null 2>&1"
  not_if "test -f #{env_output_path} && diff -q #{env_temp_path} #{env_output_path} 2>/dev/null"
  notifies :run, "execute[restart kibana]"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path} && test -f #{env_output_path}"
end

# Install CA cert (mode 0640, root:kibana — group-readable for kibana
# service user). Phase 7-tls anchor; not currently used by kibana.yml
# in Phase 3b but staged so the cutover is yaml-only.
execute "install kibana CA cert" do
  command "install -m 0640 -o root -g kibana #{ca_staging_dir}/ca.crt /etc/kibana/certs/ca.crt"
  only_if "test -f #{ca_staging_dir}/ca.crt && id kibana >/dev/null 2>&1"
  not_if "test -f /etc/kibana/certs/ca.crt && " \
         "diff -q #{ca_staging_dir}/ca.crt /etc/kibana/certs/ca.crt 2>/dev/null"
  notifies :run, "execute[restart kibana]"
end

execute "delete kibana CA staging" do
  command "rm -rf #{ca_staging_dir}"
  only_if "test -d #{ca_staging_dir} && test -f /etc/kibana/certs/ca.crt"
end

# === Service activation ===

execute "enable + start kibana" do
  command "systemctl enable --now kibana.service"
  # Gate on env file + kibana.yml — required before Kibana can usefully start.
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{kibana_yml_path} || exit 1;
    systemctl is-enabled kibana.service > /dev/null 2>&1 &&
    systemctl is-active kibana.service > /dev/null 2>&1 && exit 1 || exit 0
  SH
end

execute "restart kibana" do
  command "systemctl restart kibana.service"
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{kibana_yml_path} && id kibana >/dev/null 2>&1"
end

# === Kibana alerting setup (Phase 2 + Phase 3 of liveness plan) ===
#
# After Kibana is up, install:
#   1. Server Log connector + Uptime Status rule + Uptime TLS rule
#      (setup-alerting.sh)
#   2. 31 .es-query process-liveness rules per expected-processes.json
#      (setup-process-alerts.sh)
#
# Both scripts are idempotent (probe-then-create). The cookbook fetches
# the elastic superuser password from SSM at run time. Gated by the
# same SSM-availability check as the kibana-secrets step.

setup_alerting_script = File.join(File.dirname(__FILE__), "files", "setup-alerting.sh")
setup_process_alerts_script = File.join(File.dirname(__FILE__), "files", "setup-process-alerts.sh")
monitoring_integrations_script = File.join(File.dirname(__FILE__), "files", "install-monitoring-integrations.sh")
elastic_password_ssm = "/monitoring/elastic/elastic-password"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for #{elastic_password_ssm}",
  check_command: "aws ssm get-parameter --name #{elastic_password_ssm} " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "#{elastic_password_ssm} in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
) do
  # Wait for kibana.service to report active before running alerting scripts.
  # Each script's first phase is its own /api/status poll loop, so even on a
  # cold boot the script will wait — this only short-circuits if kibana
  # is genuinely down at converge time.
  execute "install Synthetics alerting (connector + Status + TLS rules)" do
    command <<~SH.strip
      set -euo pipefail
      KIBANA_PASSWORD=$(aws ssm get-parameter \
        --name #{elastic_password_ssm} \
        --with-decryption \
        --profile #{aws_profile} --region #{aws_region} \
        --query 'Parameter.Value' --output text)
      export KIBANA_USER=elastic
      export KIBANA_PASSWORD
      bash #{setup_alerting_script}
    SH
    user user
    only_if "systemctl is-active kibana.service >/dev/null 2>&1"
  end

  execute "install process-liveness rules (~31 .es-query rules)" do
    command <<~SH.strip
      set -euo pipefail
      KIBANA_PASSWORD=$(aws ssm get-parameter \
        --name #{elastic_password_ssm} \
        --with-decryption \
        --profile #{aws_profile} --region #{aws_region} \
        --query 'Parameter.Value' --output text)
      export KIBANA_USER=elastic
      export KIBANA_PASSWORD
      bash #{setup_process_alerts_script}
    SH
    user user
    only_if "systemctl is-active kibana.service >/dev/null 2>&1"
  end

  # Install the Elasticsearch + Kibana integration packages so the
  # agent-collected metrics-*.stack_monitoring.* data streams get the
  # monitoring-UI field aliases (timestamp/cluster_uuid/source_node). Without
  # this the Stack Monitoring UI can't find the cluster and ES nodes show
  # Offline. Idempotent; rolls over pre-existing alias-less data streams.
  execute "install Stack Monitoring integration packages (EPM)" do
    command <<~SH.strip
      set -euo pipefail
      KIBANA_PASSWORD=$(aws ssm get-parameter \
        --name #{elastic_password_ssm} \
        --with-decryption \
        --profile #{aws_profile} --region #{aws_region} \
        --query 'Parameter.Value' --output text)
      export KIBANA_USER=elastic
      export KIBANA_PASSWORD
      bash #{monitoring_integrations_script}
    SH
    user user
    only_if "systemctl is-active kibana.service >/dev/null 2>&1"
  end
end
