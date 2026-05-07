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

# Note on profile bootstrap: the original Phase 3 systematic-化 plan
# included aws-credentials here with bootstrap_profile=pve-bootstrap-ssm,
# but pve-bootstrap-ssm IAM does NOT have ssm:GetParameter on its own
# `/home-monitor/iam/pve-bootstrap-ssm/*` paths (intentional — preventing
# self-rotation as a privilege-escalation surface). aws-credentials with
# that bootstrap_profile fails with AccessDeniedException, so it is not
# included on the fleet path. The `bin/bootstrap-lxc-creds <CT>` operator
# script is the systematic-化 of the bootstrap step instead — it copies
# the profile from the PVE host (which has the creds via initial admin
# bootstrap) into a fresh LXC via `pct exec`, one-shot per host.

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
#
# Use `execute "sudo install -d"` rather than `directory ... owner "root"`
# because mitamae's mruby fork does NOT propagate the `:user` attribute
# through `run_specinfra(:change_file_owner, ...)` to a `sudo -u <user>`
# wrapping. On lxc-pro-dev mitamae runs as `shin1ohno`, so the bare
# `chown root:root` issued by the directory resource fails with EPERM.
# Mirrors the fix landed in cookbooks/node-exporter/default.rb (d1ac702).
execute "create /var/lib/node_exporter as root" do
  command "sudo install -d -m 0755 -o root -g root /var/lib/node_exporter"
  not_if "test -d /var/lib/node_exporter && " \
         "test \"$(stat -c '%U:%G:%a' /var/lib/node_exporter)\" = 'root:root:755'"
end

execute "create /var/lib/node_exporter/textfile as root" do
  command "sudo install -d -m 0755 -o root -g root /var/lib/node_exporter/textfile"
  not_if "test -d /var/lib/node_exporter/textfile && " \
         "test \"$(stat -c '%U:%G:%a' /var/lib/node_exporter/textfile)\" = 'root:root:755'"
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

    # Use `execute "sudo install -d"` rather than `directory ... owner "root"`:
    # mitamae's `:user` attribute does not propagate to a sudo wrapping for
    # the implicit chown, so on workstation LXCs (lxc-pro-dev) where mitamae
    # runs as a non-root user the directory resource fails with EPERM.
    execute "create #{root_ssh_dir} as root" do
      command "sudo install -d -m 0700 -o root -g root #{root_ssh_dir}"
      not_if "test -d #{root_ssh_dir} && " \
             "test \"$(stat -c '%U:%G:%a' #{root_ssh_dir})\" = 'root:root:700'"
    end

    # Idempotent append: grep -qF matches the FULL line (including the
    # forced-command prefix), so changing the prefix on a re-run causes the
    # entry to be re-appended. Stale entries are NOT pruned by this cookbook
    # — they need to be removed by hand, or via a future authorized_keys
    # full rewrite (e.g. integrated with cookbooks/ssh-keys, deferred).
    #
    # `sudo` is in the command rather than as a `user "root"` attribute: on
    # mitamae's mruby fork the user attribute is not reliably wrapped with
    # sudo for execute resources running on workstation (non-root) LXCs.
    execute "ensure root authorized_keys exists" do
      command "sudo touch #{authorized_keys_path} && " \
              "sudo chmod 0600 #{authorized_keys_path} && " \
              "sudo chown root:root #{authorized_keys_path}"
      not_if "test -f #{authorized_keys_path}"
    end

    # Use shell-quoted heredoc to safely embed lines that contain quotes /
    # spaces. `printf '%s\n' "$line"` avoids any backslash interpretation.
    # `sudo tee -a` rather than `>>` so the append happens as root.
    execute "append orchestrator forced-command authorized_keys entry" do
      command <<~SH.strip
        line=#{orchestrator_authkey_line.shellescape}
        sudo grep -qF "$line" #{authorized_keys_path} || printf '%s\n' "$line" | sudo tee -a #{authorized_keys_path} > /dev/null
      SH
    end

    execute "append break-glass authorized_keys entry" do
      command <<~SH.strip
        line=#{break_glass_authkey_line.shellescape}
        sudo grep -qF "$line" #{authorized_keys_path} || printf '%s\n' "$line" | sudo tee -a #{authorized_keys_path} > /dev/null
      SH
    end
  end
end
