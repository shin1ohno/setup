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
