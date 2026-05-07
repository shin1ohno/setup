# frozen_string_literal: true
#
# auto-mitamae-target: receive side of the Phase 2 fleet auto-apply system.
#
# Installs:
#   - /root/.ssh/authorized_keys entries for:
#       (a) orchestrator pubkey, prefixed with
#           command="/usr/local/bin/mitamae-runner",restrict,from="192.168.1.76"
#           (forced-command + no-pty + source-IP gate)
#       (b) break-glass pubkey, NO prefix (full shell, escape hatch)
#   - /usr/local/bin/mitamae-runner (the forced-command target itself)
#   - /var/lib/node_exporter/textfile (defensive, sibling of node-exporter)
#   - /root/setup git repo (idempotent clone — no-op if already present)
#
# Linux only — the orchestrator track for macOS (Phase 4) will use a
# different transport (launchd-pull from GitHub directly, decided at
# Phase 4 plan time).
#
# AWS profile + region match cookbooks/ssh-keys/files/devices.json so the
# IAM principal (pve-bootstrap-ssm) can read both /ssh-keys/devices/* and
# the new /ssh-keys/orchestrator/public + /ssh-keys/break-glass/public
# parameters. The matching IAM policy expansion ships in the home-monitor
# sibling PR.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys.
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "devices.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

# Phase 3 fleet learning: every fresh LXC needed pve-bootstrap-ssm
# manually written before the SSM-gated block could run (Phase 3a/3b/3c
# of the auto-mitamae rollout). Centralise the profile bootstrap by
# including aws-credentials with the fleet-wide standard config — the
# cookbook is auth-skip-safe, so on a fresh host with no auth it warns
# and continues; once `bin/bootstrap-lxc-creds <CT>` has seeded the
# profile, this idempotent SSM verify keeps it in sync if admin rotates
# the credentials.
node.reverse_merge!(
  aws_credentials: {
    bootstrap_profile: aws_profile,
    profiles: {
      aws_profile => {
        access_key_id_ssm:     "/home-monitor/iam/pve-bootstrap-ssm/access-key-id",
        secret_access_key_ssm: "/home-monitor/iam/pve-bootstrap-ssm/secret-access-key",
        region:                aws_region,
      },
    },
  }
)
include_cookbook "aws-credentials"

ORCHESTRATOR_SSM_PATH = "/ssh-keys/orchestrator/public"
BREAK_GLASS_SSM_PATH  = "/ssh-keys/break-glass/public"
ORCHESTRATOR_FROM_IP  = "192.168.1.76"
RUNNER_BIN_PATH       = "/usr/local/bin/mitamae-runner"
SETUP_REPO_DIR        = "/root/setup"
SETUP_REPO_URL        = "https://github.com/shin1ohno/setup.git"

# Defensive: ensure setup_root + per-cookbook subdir exist before any
# remote_file write. Matches the convention from cookbooks/auto-mitamae,
# cookbooks/awscli, cookbooks/eternal-terminal.
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/auto-mitamae-target" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Sibling-of-node-exporter defensive directory: the orchestrator (Phase 2b)
# writes textfile metrics here. Declared in both cookbooks so include order
# (auto-mitamae-target before node-exporter, or vice-versa) doesn't matter.
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

# AWS SSM access required to fetch orchestrator + break-glass pubkeys. Match
# the ssh-keys cookbook pattern: the check_command attempts the actual SSM
# read the cookbook will perform later (per CLAUDE.md "Auth-check gate must
# match the cookbook's actual invocation profile" rule). `aws sts
# get-caller-identity` alone passes against any default profile and is
# therefore a false gate.
orchestrator_ssm_check = "aws ssm get-parameter --name #{ORCHESTRATOR_SSM_PATH} " \
                         "--query Parameter.Value --output text " \
                         "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1"

# fetch_ssm helper — public-only, no decryption (these are public keys).
fetch_ssm = ->(path) {
  result = run_command(
    "aws ssm get-parameter" \
    " --name '#{path}'" \
    " --query 'Parameter.Value'" \
    " --output text" \
    " --profile '#{aws_profile}'" \
    " --region '#{aws_region}'",
    error: false,
  )
  if result.exit_status != 0
    MItamae.logger.warn("auto-mitamae-target: failed to fetch #{path}")
    nil
  else
    result.stdout.strip
  end
}

# Stage the runner script first — independent of SSM availability so a host
# whose AWS auth is misconfigured still gets the runner installed (the
# forced-command line is what depends on the orchestrator pubkey).
remote_file "#{node[:setup][:root]}/auto-mitamae-target/mitamae-runner.sh" do
  source "files/mitamae-runner.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0755"
end

execute "install mitamae-runner to #{RUNNER_BIN_PATH}" do
  command "sudo install -m 0755 -o root -g root " \
          "#{node[:setup][:root]}/auto-mitamae-target/mitamae-runner.sh #{RUNNER_BIN_PATH}"
  not_if "diff -q #{node[:setup][:root]}/auto-mitamae-target/mitamae-runner.sh #{RUNNER_BIN_PATH} 2>/dev/null"
end

# Idempotent clone of /root/setup. Skip if already cloned (Phase 1 hosts
# already have it; the orchestrator workflow assumes it exists).
execute "clone setup repo to #{SETUP_REPO_DIR}" do
  command "sudo git clone #{SETUP_REPO_URL} #{SETUP_REPO_DIR}"
  not_if "test -d #{SETUP_REPO_DIR}/.git"
end

# Authorized keys management — gated on SSM auth. Wrapped in
# require_external_auth so first-bootstrap on a fresh host without AWS
# credentials degrades to "warn + skip" rather than aborting the recipe
# (cookbooks/functions/default.rb:67 contract).
require_external_auth(
  tool_name: "AWS SSM access (profile=#{aws_profile}, region=#{aws_region})",
  check_command: orchestrator_ssm_check,
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "#{ORCHESTRATOR_SSM_PATH} and #{BREAK_GLASS_SSM_PATH} in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. Then press Enter.",
) do
  orchestrator_pubkey = fetch_ssm.call(ORCHESTRATOR_SSM_PATH)
  break_glass_pubkey  = fetch_ssm.call(BREAK_GLASS_SSM_PATH)

  if orchestrator_pubkey.nil? || break_glass_pubkey.nil?
    MItamae.logger.warn("auto-mitamae-target: pubkey fetch returned nil — skipping authorized_keys updates")
  else
    # Build the forced-command line. The pubkey blob is appended verbatim
    # so any `key-comment` (e.g. `orchestrator@monitoring`) carried in SSM
    # is preserved.
    orchestrator_authkey_line =
      %Q(command="#{RUNNER_BIN_PATH}",restrict,from="#{ORCHESTRATOR_FROM_IP}" #{orchestrator_pubkey})
    # Break-glass: no prefix, full shell. This is the rotation escape hatch
    # for an orchestrator-key compromise; the privkey lives offline in
    # operator-controlled storage (1Password / hardware token / paper).
    break_glass_authkey_line = break_glass_pubkey

    root_ssh_dir = "/root/.ssh"
    authorized_keys_path = "#{root_ssh_dir}/authorized_keys"

    directory root_ssh_dir do
      owner "root"
      group "root"
      mode "0700"
    end

    # Idempotent append: grep -qF matches the FULL line (including the
    # forced-command prefix), so changing the prefix on a re-run causes the
    # entry to be re-appended. Stale entries are NOT pruned by this cookbook
    # — they need to be removed by hand, or via a future authorized_keys
    # full rewrite (e.g. integrated with cookbooks/ssh-keys, deferred).
    execute "ensure root authorized_keys exists" do
      command "touch #{authorized_keys_path} && chmod 0600 #{authorized_keys_path} && chown root:root #{authorized_keys_path}"
      user "root"
      not_if "test -f #{authorized_keys_path}"
    end

    # Use shell-quoted heredoc to safely embed lines that contain quotes /
    # spaces. `printf '%s\n' "$line"` avoids any backslash interpretation.
    execute "append orchestrator forced-command authorized_keys entry" do
      command <<~SH.strip
        line=#{orchestrator_authkey_line.shellescape}
        grep -qF "$line" #{authorized_keys_path} || printf '%s\n' "$line" >> #{authorized_keys_path}
      SH
      user "root"
    end

    execute "append break-glass authorized_keys entry" do
      command <<~SH.strip
        line=#{break_glass_authkey_line.shellescape}
        grep -qF "$line" #{authorized_keys_path} || printf '%s\n' "$line" >> #{authorized_keys_path}
      SH
      user "root"
    end
  end
end
