# frozen_string_literal: true
#
# aws-credentials: write AWS CLI profiles to ~/.aws/credentials by fetching
# access keys from SSM Parameter Store. Use case: bootstrap a fresh LXC
# with the limited `pve-bootstrap-ssm` profile (ssh-keys cookbook depends
# on it) without an interactive `aws configure --profile X` per machine.
#
# Configuration via node[:aws_credentials][:profiles] hash:
#
#   node[:aws_credentials] = {
#     bootstrap_profile: nil,         # optional: existing profile used
#                                      # for the initial SSM read
#     profiles: {
#       "pve-bootstrap-ssm" => {
#         access_key_id_ssm:     "/home-monitor/iam/pve-bootstrap-ssm/access-key-id",
#         secret_access_key_ssm: "/home-monitor/iam/pve-bootstrap-ssm/secret-access-key",
#         region:                "ap-northeast-1",
#       },
#     },
#   }
#
# Bootstrap auth precedence (for fetching from SSM during this cookbook run):
#   1. node[:aws_credentials][:bootstrap_profile] (existing AWS profile)
#   2. AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY env vars
#   3. IAM role (EC2 metadata) / web identity
#
# On a fresh LXC the operator typically passes admin credentials once via
# env vars, e.g.:
#
#   AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... \
#     ./bin/mitamae local pve/lxc-<name>.rb
#
# This cookbook fetches the limited credentials from SSM with those env
# vars and writes them to ~/.aws/credentials. Subsequent runs use the
# now-stored profile and the env vars are not needed.
#
# Idempotency: aws configure get the existing aws_access_key_id and skip
# if it matches the SSM-fetched value (no rewrite, no rotation).

include_cookbook "awscli"

profiles = node.dig(:aws_credentials, :profiles) || {}
bootstrap = node.dig(:aws_credentials, :bootstrap_profile)

return if profiles.empty?

profile_arg = bootstrap ? " --profile '#{bootstrap}'" : ""

# Probe whether bootstrap auth has the SPECIFIC permission this cookbook
# needs (ssm:GetParameter on the configured paths) BEFORE running the
# real execute resources. The probe is a dry-run of the actual API call
# on the first profile's first SSM path — `aws sts get-caller-identity`
# is insufficient because it passes for any valid IAM identity, while
# a least-privilege identity (e.g. pve-bootstrap-ssm in home-monitor)
# may have valid credentials but no ssm:GetParameter on the credential
# paths it would otherwise rotate. See ~/.claude/rules/infrastructure.md
# "IAM principal that cannot self-rotate" — this rule generalisation.
#
# If the probe fails (no auth, no SSM permission, network gone, etc.)
# log a warn and return rather than aborting mitamae downstream.
first_spec = profiles.values.first
probe_path = first_spec[:access_key_id_ssm] || first_spec["access_key_id_ssm"]
probe_region = first_spec[:region] || first_spec["region"] || "ap-northeast-1"

if probe_path.nil?
  MItamae.logger.warn(
    "aws-credentials: first profile spec is missing access_key_id_ssm — " \
    "cannot probe SSM auth. Skipping profile sync."
  )
  return
end

auth_probe_cmd = "aws ssm get-parameter --name '#{probe_path}' " \
                 "--query 'Parameter.Value' --output text" \
                 "#{profile_arg} --region '#{probe_region}' > /dev/null 2>&1"
auth_probe = run_command(auth_probe_cmd, error: false)
if auth_probe.exit_status != 0
  MItamae.logger.warn(
    "aws-credentials: SSM read with bootstrap_profile=#{bootstrap || '<none>'} " \
    "failed for probe path #{probe_path}. " \
    "(AWS_ACCESS_KEY_ID=#{ENV['AWS_ACCESS_KEY_ID'] ? 'set' : 'unset'}.) " \
    "Skipping profile sync. Possible causes: bootstrap profile not yet " \
    "configured, profile lacks ssm:GetParameter on the credential paths " \
    "(common for least-privilege fleet identities — see " \
    "~/.claude/rules/infrastructure.md 'IAM principal that cannot self-rotate'), " \
    "or transient SSM unavailability. To bootstrap a fresh LXC, run " \
    "bin/bootstrap-lxc-creds <CT>. To rotate creds via this cookbook, " \
    "ensure bootstrap_profile has ssm:GetParameter on the configured " \
    "paths (admin profile or dedicated rotation IAM user)."
  )
  return
end

profiles.each do |profile_name, spec|
  region   = spec[:region] || spec["region"] || "ap-northeast-1"
  akid_ssm = spec[:access_key_id_ssm]     || spec["access_key_id_ssm"]
  sak_ssm  = spec[:secret_access_key_ssm] || spec["secret_access_key_ssm"]

  unless akid_ssm && sak_ssm
    MItamae.logger.warn("aws-credentials: skipping profile '#{profile_name}' — missing access_key_id_ssm or secret_access_key_ssm")
    next
  end

  fetch_cmd = lambda { |path|
    "aws ssm get-parameter --name '#{path}' --with-decryption " \
    "--query 'Parameter.Value' --output text" \
    "#{profile_arg} --region '#{region}'"
  }

  # Single shell pipeline: fetch both values, write all 3 settings,
  # idempotent guarded by not_if comparing aws_access_key_id.
  execute "configure aws profile #{profile_name}" do
    command <<~CMD
      AKID=$(#{fetch_cmd.call(akid_ssm)}) && \
      SAK=$(#{fetch_cmd.call(sak_ssm)})  && \
      aws configure set aws_access_key_id     "$AKID" --profile #{profile_name} && \
      aws configure set aws_secret_access_key "$SAK"  --profile #{profile_name} && \
      aws configure set region                 #{region}       --profile #{profile_name}
    CMD
    user node[:setup][:user]
    not_if <<~CMD
      AKID=$(#{fetch_cmd.call(akid_ssm)} 2>/dev/null) && \
      EXISTING=$(aws configure get aws_access_key_id --profile #{profile_name} 2>/dev/null) && \
      test -n "$AKID" && test "$AKID" = "$EXISTING"
    CMD
  end
end
