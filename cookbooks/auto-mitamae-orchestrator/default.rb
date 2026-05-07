# frozen_string_literal: true
#
# auto-mitamae-orchestrator: Phase 2b central orchestrator for the fleet
# auto-apply system. Runs on monitoring (CT 111). Two cron jobs:
#
#   - drift-checker.sh    every 2 min   poll GitHub API for setup/main HEAD
#   - orchestrator.sh     every 5 min   ssh-push mitamae-runner on each host
#
# Both write Prometheus textfile metrics under /var/lib/node_exporter/textfile/
# which the local node_exporter (cookbooks/node-exporter) exposes.
#
# Forced-command on the receive side (cookbooks/auto-mitamae-target) ensures
# the orchestrator's SSH key can ONLY invoke /usr/local/bin/mitamae-runner —
# no shell, no scp, no port forwarding. Per-host flock + SHA-pinning prevent
# TOCTOU races (drift-checker observes SHA, orchestrator passes it through,
# runner verifies before checkout).
#
# Linux only — Phase 4 will define a separate macOS pull track.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys (per
# CLAUDE.md "Auth-check gate must match the cookbook's actual invocation
# profile" rule).
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

ORCHESTRATOR_PRIVATE_KEY_PATH = "/root/.ssh/orchestrator"
ORCHESTRATOR_KNOWN_HOSTS_PATH = "/root/.ssh/known_hosts.orchestrator"
ORCHESTRATOR_SSM_PATH         = "/ssh-keys/orchestrator/private"
HOSTS_JSON_TARGET             = "/etc/auto-mitamae/hosts.json"
ORCHESTRATOR_BIN              = "/usr/local/bin/orchestrator.sh"
DRIFT_CHECKER_BIN             = "/usr/local/bin/drift-checker.sh"
BOOTSTRAP_LXC_CREDS_BIN       = "/usr/local/bin/bootstrap-lxc-creds"
CRON_FILE                     = "/etc/cron.d/auto-mitamae-orchestrator"
LOG_FILE                      = "/var/log/auto-mitamae-orchestrator.log"

# Defensive directories (per CLAUDE.md "Defensive directory resource" rule).
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/auto-mitamae-orchestrator" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Sibling-of-node-exporter defensive directory. Both auto-mitamae-target and
# this cookbook re-declare it so include order doesn't matter.
directory "/var/lib/node_exporter" do
  owner "root"
  group "root"
  mode "0755"
end

directory "/var/lib/node_exporter/textfile" do
  owner "root"
  group "root"
  mode "0755"
end

# /etc/auto-mitamae for hosts.json.
directory "/etc/auto-mitamae" do
  owner "root"
  group "root"
  mode "0755"
end

# Stage scripts under setup_root, then install with explicit perms.
%w[orchestrator.sh drift-checker.sh].each do |script|
  remote_file "#{node[:setup][:root]}/auto-mitamae-orchestrator/#{script}" do
    source "files/#{script}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "0755"
  end
end

execute "install orchestrator.sh to #{ORCHESTRATOR_BIN}" do
  command "sudo install -m 0755 -o root -g root " \
          "#{node[:setup][:root]}/auto-mitamae-orchestrator/orchestrator.sh #{ORCHESTRATOR_BIN}"
  not_if "diff -q #{node[:setup][:root]}/auto-mitamae-orchestrator/orchestrator.sh #{ORCHESTRATOR_BIN} 2>/dev/null"
end

execute "install drift-checker.sh to #{DRIFT_CHECKER_BIN}" do
  command "sudo install -m 0755 -o root -g root " \
          "#{node[:setup][:root]}/auto-mitamae-orchestrator/drift-checker.sh #{DRIFT_CHECKER_BIN}"
  not_if "diff -q #{node[:setup][:root]}/auto-mitamae-orchestrator/drift-checker.sh #{DRIFT_CHECKER_BIN} 2>/dev/null"
end

# Phase B-2: deploy bin/bootstrap-lxc-creds to /usr/local/bin/ on the
# monitoring host (CT 111). orchestrator.sh's ensure_creds() step calls
# this when an LXC's pve-bootstrap-ssm profile is invalid (e.g. after
# B-1 IAM rotation). content is read from setup/bin/bootstrap-lxc-creds
# (the canonical location for manual operator use) so a single source-
# of-truth is maintained — the file resource embeds the script content
# at compile time, eliminating any chance of drift between the manual
# tool and the orchestrator-deployed copy.
file BOOTSTRAP_LXC_CREDS_BIN do
  action :create
  owner "root"
  group "root"
  mode "0755"
  content File.read(File.expand_path("../../../bin/bootstrap-lxc-creds", __FILE__))
end

# hosts.json — root:root 0644 so cron can read it.
remote_file HOSTS_JSON_TARGET do
  source "files/hosts.json"
  owner "root"
  group "root"
  mode "0644"
end

# Orchestrator private key — fetched via SSM, gated on AWS auth so a
# bootstrap on a host without AWS creds degrades gracefully (warn + skip)
# rather than aborting the recipe.
orchestrator_ssm_check = "aws ssm get-parameter --name #{ORCHESTRATOR_SSM_PATH} " \
                         "--with-decryption --query Parameter.Value --output text " \
                         "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1"

require_external_auth(
  tool_name: "AWS SSM access (profile=#{aws_profile}, region=#{aws_region}) for orchestrator private key",
  check_command: orchestrator_ssm_check,
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "#{ORCHESTRATOR_SSM_PATH} in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(ORCHESTRATOR_PRIVATE_KEY_PATH) },
) do
  directory "/root/.ssh" do
    owner "root"
    group "root"
    mode "0700"
  end

  # fetch_ssm — capture stdout as the key body. SecureString fully decrypted.
  execute "fetch orchestrator private key into #{ORCHESTRATOR_PRIVATE_KEY_PATH}" do
    command <<~SH.strip
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      aws ssm get-parameter \
        --name #{ORCHESTRATOR_SSM_PATH} \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --profile #{aws_profile} \
        --region #{aws_region} > "$tmp" || exit 1
      install -m 0600 -o root -g root "$tmp" #{ORCHESTRATOR_PRIVATE_KEY_PATH}
    SH
    not_if "test -f #{ORCHESTRATOR_PRIVATE_KEY_PATH}"
  end
end

# Pre-create known_hosts file so orchestrator.sh's StrictHostKeyChecking=
# accept-new can append to it. mode 0600 — only root reads.
file ORCHESTRATOR_KNOWN_HOSTS_PATH do
  action :create
  owner "root"
  group "root"
  mode "0600"
  not_if "test -f #{ORCHESTRATOR_KNOWN_HOSTS_PATH}"
end

# cron — drift-checker every 2 min, orchestrator every 5 min.
# Output redirected to a single log file; systemd-cron / cronie's default
# MAILTO=root would otherwise fill /var/spool/mail with every cycle.
#
# 5-min orchestrator interval (was 15 min): the previous schedule left a
# race window of up to 15 min between drift-checker observing a new
# main HEAD and the orchestrator pushing that SHA to fleet hosts. During
# that window the orchestrator drove the OLD expected_sha while hosts
# fetched the NEW origin/main → every host emitted sha_mismatch until
# the next orchestrator cycle. 5 min caps the recovery window. Safe to
# shorten because orchestrator.sh holds /var/lock/auto-mitamae-orchestrator.lock
# (flock -n) — overlapping cycles exit cleanly with "previous cycle still
# in progress, skipping" rather than racing.
cron_content = <<~CRON
  # Auto-generated by cookbooks/auto-mitamae-orchestrator. Do not edit.
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  MAILTO=""

  */2 * * * *  root  #{DRIFT_CHECKER_BIN} >> #{LOG_FILE} 2>&1
  */5 * * * *  root  #{ORCHESTRATOR_BIN}  >> #{LOG_FILE} 2>&1
CRON

file CRON_FILE do
  action :create
  owner "root"
  group "root"
  mode "0644"
  content cron_content
end

# Ensure log file exists with sane perms — cron's append redirect creates it
# 0600 root:root by default which is fine, but pre-creating avoids a 1-cycle
# noisy "no such file" if a sysadmin tails it before first run.
file LOG_FILE do
  action :create
  owner "root"
  group "root"
  mode "0644"
  not_if "test -f #{LOG_FILE}"
end
