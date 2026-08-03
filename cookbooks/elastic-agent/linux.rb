# frozen_string_literal: true
#
# elastic-agent (Linux): standalone Elastic Agent on bare-metal pro + the PVE
# host + every service LXC + the 3 ES nodes + Kibana.
#
# APT package install + systemd service. Config rendered from
# elastic-agent.linux.yml.tmpl, password injected via EnvironmentFile=
# populated by generate_env.sh (SSM fetch). Optional per-host integration
# inputs (prometheus federation, synthetics, stack / ES-node monitoring, AWS
# billing) are spliced in at their @@*_INPUT@@ placeholders.
#
# Ships to the 3-node ES cluster (es-{0,1,2}.home.local) as the
# `elastic_agent_writer` ES user, password at SSM
# /monitoring/elastic/elastic-agent-password.
#
# Stream-O Fleet Server pivot (2026-05-09): Fleet Server was abandoned as
# overkill for a ~16-host home fleet. Standalone mode requires no enrollment
# token — each host ships a static elastic-agent.yml plus an SSM-fetched
# password.
#
# Per-host attributes (set in entry recipe / lxc_entry before include):
#   node[:elastic_agent][:host_name]                             short hostname
#   node[:elastic_agent][:tags]                                  array of tags
#   node[:elastic_agent][:enable_prometheus_integration]         CT 111 only
#   node[:elastic_agent][:enable_synthetics_integration]
#   node[:elastic_agent][:enable_stack_monitoring_integration]
#   node[:elastic_agent][:enable_es_node_monitoring_integration]
#   node[:elastic_agent][:enable_aws_billing_integration]        CT 111 only
#
# macOS counterpart: darwin.rb (tarball + launchd).
#
# Operator apply (LXC, from inside the CT):
#   ./bin/mitamae local pve/lxc-<name>.rb

include_cookbook "awscli"

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user  = node[:setup][:user]
group = node[:setup][:group]

host_name = (node[:elastic_agent] && node[:elastic_agent][:host_name]) ||
            run_command("hostname -s", error: false).stdout.strip
tags = (node[:elastic_agent] && node[:elastic_agent][:tags]) || ["lxc"]
tags_json = "[" + tags.map { |t| %("#{t}") }.join(", ") + "]"

enable_prom_input = node[:elastic_agent] &&
                    node[:elastic_agent][:enable_prometheus_integration]
enable_synth_input = node[:elastic_agent] &&
                     node[:elastic_agent][:enable_synthetics_integration]
enable_stack_input = node[:elastic_agent] &&
                     node[:elastic_agent][:enable_stack_monitoring_integration]
enable_es_node_input = node[:elastic_agent] &&
                       node[:elastic_agent][:enable_es_node_monitoring_integration]
enable_aws_billing_input = node[:elastic_agent] &&
                           node[:elastic_agent][:enable_aws_billing_integration]

# Defensive directory bootstrap
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/elastic-agent" do
  owner user
  group group
  mode "755"
end

files_dir = "#{node[:setup][:root]}/elastic-agent/files"
directory files_dir do
  owner user
  group group
  mode "755"
end

# === Elastic apt repo registration ===

execute "install elastic apt prerequisites (elastic-agent)" do
  command "apt-get install -y ca-certificates curl gnupg apt-transport-https"
  not_if {
    %w(ca-certificates curl gnupg apt-transport-https).all? { |pkg|
      run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0
    }
  }
end

execute "add elastic apt key (elastic-agent)" do
  command <<~SH.strip
    install -d -m 0755 /etc/apt/keyrings && \
      curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
      gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg && \
      chmod a+r /etc/apt/keyrings/elastic.gpg
  SH
  not_if { File.exist?("/etc/apt/keyrings/elastic.gpg") }
end

execute "add elastic apt repo (elastic-agent)" do
  command "echo 'deb [signed-by=/etc/apt/keyrings/elastic.gpg] " \
          "https://artifacts.elastic.co/packages/9.x/apt stable main' " \
          "> /etc/apt/sources.list.d/elastic-9.x.list"
  not_if "test -f /etc/apt/sources.list.d/elastic-9.x.list && " \
         "grep -q 'artifacts.elastic.co' /etc/apt/sources.list.d/elastic-9.x.list"
  notifies :run, "execute[apt-get update for elastic-agent]", :immediately
end

execute "apt-get update for elastic-agent" do
  command "apt-get update -qq"
  action :nothing
end

# === Install Elastic Agent DEB ===

execute "install elastic-agent 9.4.2" do
  command "apt-get install -y elastic-agent=9.4.2"
  not_if "dpkg-query -W -f='${Version}' elastic-agent 2>/dev/null | grep -q '^9.4.2$'"
end

execute "apt-mark hold elastic-agent" do
  command "apt-mark hold elastic-agent"
  not_if "apt-mark showhold | grep -q '^elastic-agent$'"
end

# === Stage cookbook files (config template + env generator + systemd override) ===

%w[
  elastic-agent.linux.yml.tmpl
  elastic-agent.service.override.conf
  elastic-agent.prometheus-input.yml
  elastic-agent.synthetics-input.yml
  elastic-agent.stack-monitoring-input.yml
  elastic-agent.es-node-monitoring-input.yml
  elastic-agent.aws-billing-input.yml
].each do |f|
  remote_file "#{files_dir}/#{f}" do
    source "files/#{f}"
    owner user
    group group
    mode "0644"
  end
end

remote_file "#{files_dir}/generate_env.sh" do
  source "files/generate_env.sh"
  owner user
  group group
  mode "0755"
end

# === SSM-gated env file generation ===

env_temp_path   = "#{node[:setup][:root]}/elastic-agent/elastic-agent.yml.env"
env_output_path = "/etc/elastic-agent/elastic-agent.yml.env"
config_tmpl     = "#{files_dir}/elastic-agent.linux.yml.tmpl"
config_path     = "/etc/elastic-agent/elastic-agent.yml"
override_dir    = "/etc/systemd/system/elastic-agent.service.d"
override_path   = "#{override_dir}/override.conf"
override_src    = "#{files_dir}/elastic-agent.service.override.conf"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/elastic-agent-password",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/elastic-agent-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  # Content-aware skip (per ~/.claude/rules/ruby.md "SSM-sourced .env generator:
  # file-existence skip_if drops new KEY=VALUE lines silently"): on the billing
  # host the env file may already exist from a prior apply that predates the AWS
  # keys, so a bare File.exist? would never add them. Regenerate when billing is
  # enabled but AWS_ACCESS_KEY_ID= is absent. Non-billing hosts keep the original
  # file-existence behavior (short-circuits before File.read, so no read of the
  # 0640 root env file is attempted where mitamae runs as a non-root user).
  skip_if: -> {
    env_present = File.exist?(env_output_path)
    if !env_present
      false
    elsif !enable_aws_billing_input
      true
    else
      begin
        File.read(env_output_path).include?("AWS_ACCESS_KEY_ID=")
      rescue StandardError
        false
      end
    end
  },
) do
  execute "generate elastic-agent.yml.env" do
    # ENABLE_AWS_BILLING=1 only on the billing host (CT 111) so generate_env.sh
    # fetches + appends the AWS billing creds there and nowhere else.
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "#{enable_aws_billing_input ? 'ENABLE_AWS_BILLING=1 ' : ''}" \
            "bash #{files_dir}/generate_env.sh #{env_temp_path}"
    user user
  end
end

execute "install elastic-agent.yml.env" do
  # sudo prefix supports both root mitamae (service LXCs, no-op) and
  # regular-user mitamae (dev-workstation LXCs like pro-dev / bare-metal).
  command "sudo install -m 0640 -o root -g root #{env_temp_path} #{env_output_path}"
  only_if "test -f #{env_temp_path} && test -d /etc/elastic-agent"
  not_if "test -f #{env_output_path} && sudo diff -q #{env_temp_path} #{env_output_path} 2>/dev/null"
  notifies :run, "execute[restart elastic-agent]"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path} && test -f #{env_output_path}"
end

# === Phase 7-tls: fetch ES CA cert into /etc/elastic-agent/certs/ ===
#
# elastic-agent.yml output.default.ssl.certificate_authorities references
# /etc/elastic-agent/certs/ca.crt. Fetch from SSM /monitoring/elastic/ca/cert
# (placed there by Phase 1b TF). Same pattern as cookbooks/lxc-kibana
# fetch_ca.sh.

ca_temp_path   = "#{node[:setup][:root]}/elastic-agent/ca.crt"
ca_output_path = "/etc/elastic-agent/certs/ca.crt"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/ca/cert",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/ca/cert " \
                 "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/ca/cert in #{aws_region}.",
  # Existence + PEM shape (see the same guard in cookbooks/lxc-monitoring): a
  # half-written or error-text ca.crt re-fetches instead of counting as done.
  # NOT rotation detection — TODO.md tracks the value-drift gap. Mode 0644, so
  # File.read is safe on the dev-workstation non-root applies too.
  skip_if: -> { file_has_all?(ca_output_path, ["BEGIN CERTIFICATE"]) },
) do
  execute "fetch elastic-agent CA cert" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "aws ssm get-parameter --name /monitoring/elastic/ca/cert " \
            "--query 'Parameter.Value' --output text > #{ca_temp_path} && " \
            "chmod 644 #{ca_temp_path}"
    user user
  end
end

execute "install elastic-agent CA cert" do
  command "sudo install -d -m 0755 -o root -g root /etc/elastic-agent/certs && " \
          "sudo install -m 0644 -o root -g root #{ca_temp_path} #{ca_output_path}"
  only_if "test -f #{ca_temp_path}"
  not_if "test -f #{ca_output_path} && sudo diff -q #{ca_temp_path} #{ca_output_path} 2>/dev/null"
  notifies :run, "execute[restart elastic-agent]"
end

file ca_temp_path do
  action :delete
  only_if "test -f #{ca_temp_path} && test -f #{ca_output_path}"
end

# === Render elastic-agent.yml from template ===

prom_input_path = "#{files_dir}/elastic-agent.prometheus-input.yml"
prom_sed_clause = if enable_prom_input
                    "-e '/@@PROMETHEUS_INPUT@@/r #{prom_input_path}' " \
                    "-e '/@@PROMETHEUS_INPUT@@/d'"
                  else
                    "-e '/@@PROMETHEUS_INPUT@@/d'"
                  end

synth_input_path = "#{files_dir}/elastic-agent.synthetics-input.yml"
synth_sed_clause = if enable_synth_input
                     "-e '/@@SYNTHETICS_INPUT@@/r #{synth_input_path}' " \
                     "-e '/@@SYNTHETICS_INPUT@@/d'"
                   else
                     "-e '/@@SYNTHETICS_INPUT@@/d'"
                   end

stack_input_path = "#{files_dir}/elastic-agent.stack-monitoring-input.yml"
stack_sed_clause = if enable_stack_input
                     "-e '/@@STACK_MONITORING_INPUT@@/r #{stack_input_path}' " \
                     "-e '/@@STACK_MONITORING_INPUT@@/d'"
                   else
                     "-e '/@@STACK_MONITORING_INPUT@@/d'"
                   end

es_node_input_path = "#{files_dir}/elastic-agent.es-node-monitoring-input.yml"
es_node_sed_clause = if enable_es_node_input
                       "-e '/@@ES_NODE_MONITORING_INPUT@@/r #{es_node_input_path}' " \
                       "-e '/@@ES_NODE_MONITORING_INPUT@@/d'"
                     else
                       "-e '/@@ES_NODE_MONITORING_INPUT@@/d'"
                     end

aws_billing_input_path = "#{files_dir}/elastic-agent.aws-billing-input.yml"
aws_billing_sed_clause = if enable_aws_billing_input
                           "-e '/@@AWS_BILLING_INPUT@@/r #{aws_billing_input_path}' " \
                           "-e '/@@AWS_BILLING_INPUT@@/d'"
                         else
                           "-e '/@@AWS_BILLING_INPUT@@/d'"
                         end

execute "render elastic-agent.yml" do
  # Stage in user-writable /tmp then sudo install. mitamae on dev-workstation
  # LXCs (e.g. pro-dev CT 104) runs as the regular user — direct write to
  # /etc/elastic-agent/ fails with EACCES. Service LXCs run mitamae as root
  # so sudo is a no-op there.
  staging = "/tmp/elastic-agent.yml.render.$$"
  # Two-pass sed: pass 1 splices the per-integration input files in at their
  # @@*_INPUT@@ placeholders (sed `r` appends file content AFTER the cycle, so
  # it is NOT seen by an `s///` in the same invocation); pass 2 substitutes
  # @@HOSTNAME@@/@@TAGS@@ over the FULLY assembled output so placeholders
  # INSIDE a spliced input file (e.g. es-node-monitoring's per-node
  # https://@@HOSTNAME@@.home.local:9200 host) are also resolved.
  command <<~SH.strip
    set -euo pipefail
    sed #{prom_sed_clause} \\
        #{synth_sed_clause} \\
        #{stack_sed_clause} \\
        #{es_node_sed_clause} \\
        #{aws_billing_sed_clause} \\
      #{config_tmpl} \\
      | sed -e "s|@@HOSTNAME@@|#{host_name}|g" -e 's|@@TAGS@@|#{tags_json}|g' > #{staging}
    sudo install -m 0640 -o root -g root #{staging} #{config_path}
    rm -f #{staging}
  SH
  only_if "test -f #{config_tmpl} && test -d /etc/elastic-agent"
  # mitamae executes not_if via /bin/sh -c, which on Debian/Ubuntu is dash.
  # dash does not support `<(...)` process substitution, so the raw form
  # raises `Syntax error: "(" unexpected`, exits non-zero, and mitamae
  # treats the guard as "not satisfied" — firing render + restart on every
  # apply. Render to a temp file and use plain `diff` (POSIX-compatible).
  not_if "test -f #{config_path} && " \
         "rendered=$(mktemp) && " \
         "sed #{prom_sed_clause} " \
         "#{synth_sed_clause} " \
         "#{stack_sed_clause} " \
         "#{es_node_sed_clause} " \
         "#{aws_billing_sed_clause} " \
         "#{config_tmpl} " \
         "| sed -e 's|@@HOSTNAME@@|#{host_name}|g' " \
         "-e 's|@@TAGS@@|#{tags_json}|g' > \"$rendered\" && " \
         "diff -q \"$rendered\" #{config_path}; " \
         "ret=$?; rm -f \"$rendered\"; exit $ret"
  notifies :run, "execute[restart elastic-agent]"
end

# === systemd override ===

execute "create elastic-agent.service.d directory" do
  command "install -d -m 0755 -o root -g root #{override_dir}"
  not_if "test -d #{override_dir}"
end

execute "install elastic-agent systemd override" do
  command "sudo install -m 0644 -o root -g root #{override_src} #{override_path}"
  only_if "test -f #{override_src}"
  not_if "test -f #{override_path} && diff -q #{override_src} #{override_path} 2>/dev/null"
  notifies :run, "execute[elastic-agent daemon-reload]", :immediately
  notifies :run, "execute[restart elastic-agent]"
end

execute "elastic-agent daemon-reload" do
  command "sudo systemctl daemon-reload"
  action :nothing
end

# === Service activation ===

execute "enable + start elastic-agent" do
  command "sudo systemctl enable --now elastic-agent.service"
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{config_path} || exit 1;
    systemctl is-enabled elastic-agent.service > /dev/null 2>&1 &&
    systemctl is-active elastic-agent.service > /dev/null 2>&1 && exit 1 || exit 0
  SH
end

execute "restart elastic-agent" do
  command "sudo systemctl restart elastic-agent.service"
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{config_path}"
end
