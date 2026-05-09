# frozen_string_literal: true
#
# elastic-agent: standalone Elastic Agent 8.16 on every Linux host in the
# fleet (bare-metal pro + PVE host + 13 service LXCs). Each agent ships
# system metrics + syslog/auth filestreams to the 3-node ES cluster
# (es-{0,1,2}.home.local) using a dedicated ES user `elastic_agent_writer`
# with SSM-managed password.
#
# Stream-O Fleet Server pivot (2026-05-09): Fleet Server was abandoned as
# overkill for a ~16-host home fleet. Standalone mode requires no enrollment
# token — each host ships a static elastic-agent.yml plus an SSM-fetched
# password env file.
#
# Per-host attributes (set in entry recipe before include):
#   node[:elastic_agent][:host_name]  short hostname (default: `hostname -s`)
#   node[:elastic_agent][:tags]       array of tags (default: ["lxc"])
#
# Skipped on macOS — see Stream Q for the macOS Elastic Agent install path.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so the
# require_external_auth check_command and the SSM fetch script all target
# the same IAM principal.
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

user  = node[:setup][:user]
group = node[:setup][:group]

host_name = (node[:elastic_agent] && node[:elastic_agent][:host_name]) ||
            run_command("hostname -s", error: false).stdout.strip
tags = (node[:elastic_agent] && node[:elastic_agent][:tags]) || ["lxc"]
tags_json = "[" + tags.map { |t| %("#{t}") }.join(", ") + "]"

# Defensive: ensure setup_root + per-cookbook subdir exist before any
# remote_file write (per CLAUDE.md "Defensive directory resource").
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
#
# Same shape as cookbooks/lxc-elasticsearch — keyring at /etc/apt/keyrings,
# signed-by repo entry. Idempotent: each step gates on observable target state.

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
          "https://artifacts.elastic.co/packages/8.x/apt stable main' " \
          "> /etc/apt/sources.list.d/elastic-8.x.list"
  not_if "test -f /etc/apt/sources.list.d/elastic-8.x.list && " \
         "grep -q 'artifacts.elastic.co' /etc/apt/sources.list.d/elastic-8.x.list"
  notifies :run, "execute[apt-get update for elastic-agent]", :immediately
end

execute "apt-get update for elastic-agent" do
  command "apt-get update -qq"
  action :nothing
end

# === Install Elastic Agent DEB ===

execute "install elastic-agent 8.16.0" do
  command "apt-get install -y elastic-agent=8.16.0"
  not_if "dpkg-query -W -f='${Version}' elastic-agent 2>/dev/null | grep -q '^8.16.0$'"
end

execute "apt-mark hold elastic-agent" do
  command "apt-mark hold elastic-agent"
  not_if "apt-mark showhold | grep -q '^elastic-agent$'"
end

# === Stage cookbook files (config template + env generator + systemd override) ===

%w[
  elastic-agent.yml.tmpl
  elastic-agent.service.override.conf
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
#
# elastic_agent_writer password lives at /monitoring/elastic/elastic-agent-password
# (SecureString, KMS-encrypted). pve-bootstrap-ssm IAM has Decrypt scope via
# /monitoring/elastic/* wildcard — no IAM change needed.

env_temp_path   = "#{node[:setup][:root]}/elastic-agent/elastic-agent.yml.env"
env_output_path = "/etc/elastic-agent/elastic-agent.yml.env"
config_tmpl     = "#{files_dir}/elastic-agent.yml.tmpl"
config_path     = "/etc/elastic-agent/elastic-agent.yml"
override_dir    = "/etc/systemd/system/elastic-agent.service.d"
override_path   = "#{override_dir}/override.conf"
override_src    = "#{files_dir}/elastic-agent.service.override.conf"

# require_external_auth: probe the actual SSM read the cookbook will perform.
# Per CLAUDE.md "Auth-check gate must match the cookbook's actual invocation
# profile" — gated to the named profile, not bare `sts get-caller-identity`.
require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/elastic-agent-password",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/elastic-agent-password " \
                 "--with-decryption --profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate elastic-agent.yml.env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{files_dir}/generate_env.sh #{env_temp_path}"
    user user
  end
end

# /etc/elastic-agent is created by the DEB postinst (mode 0750 root:root).
# Install the env file with mode 0640 root:root — DEB runs the agent as root
# so root:root is correct (no `elastic-agent` user is created by the DEB).
execute "install elastic-agent.yml.env" do
  command "install -m 0640 -o root -g root #{env_temp_path} #{env_output_path}"
  only_if "test -f #{env_temp_path} && test -d /etc/elastic-agent"
  not_if "test -f #{env_output_path} && diff -q #{env_temp_path} #{env_output_path} 2>/dev/null"
  notifies :run, "execute[restart elastic-agent]"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path} && test -f #{env_output_path}"
end

# === Render elastic-agent.yml from template ===

execute "render elastic-agent.yml" do
  command <<~SH.strip
    set -euo pipefail
    sed -e "s|@@HOSTNAME@@|#{host_name}|g" \\
        -e 's|@@TAGS@@|#{tags_json}|g' \\
      #{config_tmpl} > #{config_path}.new
    install -m 0640 -o root -g root #{config_path}.new #{config_path}
    rm -f #{config_path}.new
  SH
  only_if "test -f #{config_tmpl} && test -d /etc/elastic-agent"
  not_if "test -f #{config_path} && " \
         "diff -q <(sed -e 's|@@HOSTNAME@@|#{host_name}|g' " \
         "-e 's|@@TAGS@@|#{tags_json}|g' #{config_tmpl}) " \
         "#{config_path}"
  notifies :run, "execute[restart elastic-agent]"
end

# === systemd override ===

execute "create elastic-agent.service.d directory" do
  command "install -d -m 0755 -o root -g root #{override_dir}"
  not_if "test -d #{override_dir}"
end

execute "install elastic-agent systemd override" do
  command "install -m 0644 -o root -g root #{override_src} #{override_path}"
  only_if "test -f #{override_src}"
  not_if "test -f #{override_path} && diff -q #{override_src} #{override_path} 2>/dev/null"
  notifies :run, "execute[elastic-agent daemon-reload]", :immediately
  notifies :run, "execute[restart elastic-agent]"
end

execute "elastic-agent daemon-reload" do
  command "systemctl daemon-reload"
  action :nothing
end

# === Service activation ===
#
# Gate on env file + config file + override — all three required for the unit
# to usefully start. The DEB enables but does not start the service by default;
# we enable+start in one step.

execute "enable + start elastic-agent" do
  command "systemctl enable --now elastic-agent.service"
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    test -f #{config_path} || exit 1;
    systemctl is-enabled elastic-agent.service > /dev/null 2>&1 &&
    systemctl is-active elastic-agent.service > /dev/null 2>&1 && exit 1 || exit 0
  SH
end

execute "restart elastic-agent" do
  command "systemctl restart elastic-agent.service"
  action :nothing
  only_if "test -f #{env_output_path} && test -f #{config_path}"
end
