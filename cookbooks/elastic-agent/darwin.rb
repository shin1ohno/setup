# frozen_string_literal: true
#
# elastic-agent (macOS): standalone Elastic Agent on air / neo.
#
# Tarball + `elastic-agent install` subcommand (drops a launchd plist). Config
# rendered by generate_config.sh (sed-style substitution including the
# SSM-fetched password — launchd has no EnvironmentFile equivalent and
# standalone-mode agents do not support secret refs in the output password).
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
# Per-host attributes (set in entry recipe before include):
#   node[:elastic_agent][:version]      defaults to 9.4.2
#   node[:elastic_agent][:aws_profile]  defaults to sh1admn
#
# Linux counterpart: linux.rb (APT + systemd). No shared sub-recipe — the two
# paths share only `include_cookbook "awscli"` plus two node reads, and hoisting
# those would move awscli's resources AHEAD of the fleet-membership return below.
#
# Operator apply:
#   ./bin/mitamae local darwin.rb

# Identity is resolved once by cookbooks/host-profile (node[:profile][:label]).
# The macOS Elastic Agent converges only on the Mac fleet (Air + neo); pro is
# bare-metal Linux and takes the Linux path. variant == the label.
variant = node[:profile][:label]

unless ["air", "neo"].include?(variant)
  MItamae.logger.warn(
    "elastic-agent: host '#{node[:profile][:hostname]}' (node[:profile][:label]=" \
    "#{variant.inspect}) is not in the macOS Elastic Agent fleet (air/neo) — " \
    "no Elastic Agent installed on this host."
  )
  return
end

include_cookbook "awscli::darwin"

user       = node[:setup][:user]
group      = node[:setup][:group]
setup_root = node[:setup][:root]

ea_version  = node.dig(:elastic_agent, :version) || "9.4.2"
# darwin: admin profile (sh1admn) by default — Macs are not seeded with the
# fleet bootstrap profile pve-bootstrap-ssm. Overridable via
# node[:elastic_agent][:aws_profile]. (linux.rb resolves pve-bootstrap-ssm from
# aws-config.json — see CLAUDE.md "AWS profile resolution".)
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

# Arch comes from the host-profile fact (raw `uname -m`), not a per-cookbook
# re-probe. Elastic's darwin tarballs are published as x86_64 / aarch64, so
# Apple silicon's arm64 still needs the rename.
ea_arch = case node[:hw][:machine]
          when "arm64"  then "aarch64"
          when "x86_64" then "x86_64"
          else
            raise "elastic-agent: unsupported macOS arch '#{node[:hw][:machine]}'"
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
