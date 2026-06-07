# frozen_string_literal: true
#
# elastic-agent: standalone Elastic Agent 8.16 across the fleet.
#
# Two install paths, branched on node[:platform]:
#
#   * Linux (bare-metal pro + PVE host + 13 service LXCs + 3 ES nodes + Kibana):
#     APT package install + systemd service. Config rendered from
#     elastic-agent.linux.yml.tmpl, password injected via EnvironmentFile=
#     populated by generate_env.sh (SSM fetch). Includes optional
#     prometheus federation input on hosts that opt in via
#     node[:elastic_agent][:enable_prometheus_integration] (today: CT 111
#     lxc-monitoring only).
#
#   * macOS (air, ohnos-macbook): tarball + `elastic-agent install`
#     subcommand (drops launchd plist). Config rendered by generate_config.sh
#     (sed-style substitution including the SSM-fetched password — launchd
#     has no EnvironmentFile equivalent and standalone-mode agents do not
#     support secret refs in the output password).
#
# Both paths target the 3-node ES cluster (es-{0,1,2}.home.local) using the
# `elastic_agent_writer` ES user with SSM-managed password at
# /monitoring/elastic/elastic-agent-password.
#
# Stream-O Fleet Server pivot (2026-05-09): Fleet Server was abandoned as
# overkill for a ~16-host home fleet. Standalone mode requires no enrollment
# token — each host ships a static elastic-agent.yml plus an SSM-fetched
# password.
#
# Per-host attributes (set in entry recipe before include):
#   node[:elastic_agent][:host_name]                       short hostname
#   node[:elastic_agent][:tags]                            array of tags
#   node[:elastic_agent][:enable_prometheus_integration]   Linux only
#   node[:elastic_agent][:version]                         macOS only (default 9.4.2)
#
# Operator apply (macOS):
#   ./bin/mitamae local darwin.rb
# Operator apply (Linux LXC, from inside CT):
#   ./bin/mitamae local pve/lxc-<name>.rb

if node[:platform] == "darwin"
  # ============================================================================
  # macOS path: tarball install + launchd
  # ============================================================================

  # Identity is resolved once by cookbooks/host-profile (node[:profile][:label]).
  # The macOS Elastic Agent converges only on the Mac fleet (Air + neo); pro is
  # bare-metal Linux and takes the Linux path below. variant == the label.
  variant = node[:profile][:label]

  unless ["air", "neo"].include?(variant)
    MItamae.logger.warn(
      "elastic-agent: host '#{node[:profile][:hostname]}' (node[:profile][:label]=" \
      "#{variant.inspect}) is not in the macOS Elastic Agent fleet (air/neo) — " \
      "no Elastic Agent installed on this host."
    )
    return
  end

  include_cookbook "awscli"

  user       = node[:setup][:user]
  group      = node[:setup][:group]
  setup_root = node[:setup][:root]

  ea_version  = node.dig(:elastic_agent, :version) || "9.4.2"
  aws_profile = node.dig(:elastic_agent, :aws_profile) || "sh1admn"
  aws_region  = node.dig(:elastic_agent, :aws_region)  || "ap-northeast-1"
  es_password_ssm = node.dig(:elastic_agent, :es_password_ssm) ||
                    "/monitoring/elastic/elastic-agent-password"
  es_username = node.dig(:elastic_agent, :es_username) || "elastic_agent_writer"
  # Phase 7-tls: HTTPS to ES cluster. CA cert installed at
  # /Library/Elastic/Agent/ca.crt by the macOS install path below
  # (fetched from SSM /monitoring/elastic/ca/cert).
  es_hosts = node.dig(:elastic_agent, :es_hosts) || %w[
    https://es-0.home.local:9200
    https://es-1.home.local:9200
    https://es-2.home.local:9200
  ]

  arch = run_command("uname -m").stdout.strip
  ea_arch = case arch
            when "arm64"  then "aarch64"
            when "x86_64" then "x86_64"
            else
              raise "elastic-agent: unsupported macOS arch '#{arch}'"
            end

  tarball_name = "elastic-agent-#{ea_version}-darwin-#{ea_arch}.tar.gz"
  tarball_url  = "https://artifacts.elastic.co/downloads/beats/elastic-agent/#{tarball_name}"
  sha512_url   = "#{tarball_url}.sha512"

  # === Defensive directory bootstrap ===
  directory setup_root do
    owner user
    group group
    mode "755"
  end

  cookbook_stage = "#{setup_root}/elastic-agent"
  directory cookbook_stage do
    owner user
    group group
    mode "755"
  end

  tarball_path = "#{cookbook_stage}/#{tarball_name}"
  sha512_path  = "#{cookbook_stage}/#{tarball_name}.sha512"
  extract_dir  = "#{cookbook_stage}/elastic-agent-#{ea_version}-darwin-#{ea_arch}"

  # === Tarball download + SHA-512 verification ===
  ea_installed_path = "/Library/Elastic/Agent/elastic-agent"

  execute "download elastic-agent #{ea_version} tarball" do
    command "curl -fsSL -o #{tarball_path} #{tarball_url}"
    user user
    not_if "test -f #{tarball_path}"
  end

  execute "download elastic-agent #{ea_version} sha512" do
    command "curl -fsSL -o #{sha512_path} #{sha512_url}"
    user user
    not_if "test -f #{sha512_path}"
  end

  execute "verify elastic-agent tarball sha512" do
    command "cd #{cookbook_stage} && shasum -a 512 -c #{tarball_name}.sha512"
    user user
    only_if "test -f #{tarball_path} && test -f #{sha512_path}"
    not_if "test -d #{extract_dir}"
  end

  execute "extract elastic-agent tarball" do
    command "tar -xzf #{tarball_path} -C #{cookbook_stage}"
    user user
    only_if "test -f #{tarball_path}"
    not_if "test -d #{extract_dir}"
  end

  # === sudo install (Elastic Agent installer) ===
  ea_check_version = "sudo test -x #{ea_installed_path} && " \
                     "sudo #{ea_installed_path} version 2>/dev/null | " \
                     "grep -q 'elastic-agent[[:space:]]\\+#{ea_version}'"
  ea_check_loaded  = "sudo launchctl list co.elastic.elastic-agent >/dev/null 2>&1"

  # Purge partial / broken-install state so the next `install --force` — which
  # uninstalls the existing copy first — always operates on a clean slate.
  #
  # Two failure shapes hit this:
  #   (a) install interrupted before enrollment, no launchctl entry. The leftover
  #       elastic-agent.yml lacks `agent.id`, so `uninstall` aborts with
  #       `missing field accessing 'agent'` and the reinstall never proceeds.
  #   (b) a launchctl entry IS present but the daemon is dead (socket gone) and
  #       the config is still partial — `install --force`'s uninstall step then
  #       fails the same way (or on a stuck watcher: `FillPidMetrics ... sysctl:
  #       input/output error`).
  #
  # The old guard only caught (a) (launchctl entry absent), so (b) slipped
  # through and aborted the apply. Trigger on the FUNCTIONAL signal instead:
  # the agent dir exists but `elastic-agent status` can't reach a healthy
  # daemon. That covers both shapes. No-op on healthy installs (status → 0)
  # and on first-time installs (directory absent).
  ea_healthy = "sudo #{ea_installed_path} status >/dev/null 2>&1"

  execute "purge partial elastic-agent install" do
    command "sudo launchctl unload " \
              "/Library/LaunchDaemons/co.elastic.elastic-agent.plist " \
              "2>/dev/null; " \
            "sudo rm -f /Library/LaunchDaemons/co.elastic.elastic-agent.plist " \
                      "/usr/local/bin/elastic-agent && " \
            "sudo rm -rf /Library/Elastic/Agent"
    user "root"
    only_if "sudo test -d /Library/Elastic/Agent && ! #{ea_healthy}"
  end

  execute "sudo install elastic-agent #{ea_version}" do
    command "cd #{extract_dir} && " \
            "sudo ./elastic-agent install --non-interactive --force"
    user "root"
    only_if "test -x #{extract_dir}/elastic-agent"
    not_if "#{ea_check_version} && #{ea_check_loaded}"
  end

  # === SSM-gated config render ===
  config_template = "#{cookbook_stage}/elastic-agent.darwin.yml.tmpl"
  config_staging  = "#{cookbook_stage}/elastic-agent.yml.rendered"
  config_target   = "/Library/Elastic/Agent/elastic-agent.yml"

  remote_file config_template do
    source "files/elastic-agent.darwin.yml.tmpl"
    owner user
    group group
    mode "0644"
  end

  generate_config_script = "#{cookbook_stage}/generate_config.sh"
  remote_file generate_config_script do
    source "files/generate_config.sh"
    owner user
    group group
    mode "0755"
  end

  es_hosts_yaml = es_hosts.map { |h| "    - #{h}" }.join("\n")

  require_external_auth(
    tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for #{es_password_ssm}",
    check_command: "aws ssm get-parameter --name '#{es_password_ssm}' " \
                   "--with-decryption --profile '#{aws_profile}' " \
                   "--region '#{aws_region}' > /dev/null 2>&1",
    instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                  "'#{es_password_ssm}' in #{aws_region}. " \
                  "On a fresh Mac: aws configure --profile #{aws_profile}. " \
                  "Then press Enter.",
    skip_if: -> {
      File.exist?(config_target) &&
        run_command(
          "sudo grep -q 'username: #{es_username}' #{config_target} 2>/dev/null",
          error: false,
        ).exit_status == 0
    },
  ) do
    execute "render elastic-agent.yml from SSM" do
      command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
              "ES_PASSWORD_SSM='#{es_password_ssm}' " \
              "ES_USERNAME='#{es_username}' " \
              "VARIANT='#{variant}' " \
              "TEMPLATE='#{config_template}' " \
              "OUTPUT='#{config_staging}' " \
              "ES_HOSTS_YAML=\"#{es_hosts_yaml}\" " \
              "bash #{generate_config_script}"
      user user
    end
  end

  execute "install elastic-agent.yml" do
    command "sudo install -m 0600 -o root -g wheel #{config_staging} #{config_target}"
    user user
    only_if "test -f #{config_staging}"
    not_if "sudo test -f #{config_target} && " \
           "sudo cmp -s #{config_staging} #{config_target}"
    notifies :run, "execute[restart elastic-agent launchd]"
  end

  execute "delete elastic-agent.yml staging" do
    command "rm -f #{config_staging}"
    user user
    only_if "test -f #{config_staging} && sudo test -f #{config_target}"
  end

  execute "restart elastic-agent launchd" do
    command "sudo launchctl kickstart -k system/co.elastic.elastic-agent"
    user user
    action :nothing
  end

  return
end

# ============================================================================
# Linux path: APT install + systemd service
# ============================================================================

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
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate elastic-agent.yml.env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
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
  skip_if: -> { File.exist?(ca_output_path) },
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
