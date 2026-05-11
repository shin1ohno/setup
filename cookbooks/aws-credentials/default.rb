# frozen_string_literal: true
#
# aws-credentials: bootstrap fleet AWS CLI auth on fresh hosts.
#
# Two-stage:
#
#   1. login_profiles: write [profile <name>] login_session = <iam-user-arn>
#      to ~/.aws/config so `aws login --profile <name> --remote` (AWS CLI
#      v2.34+ device-code flow) can fetch temp creds from a console
#      session. login_session ARN is non-secret; identifies the principal
#      whose console session backs the login.
#
#   2. profiles: fetch service-identity access keys from SSM Parameter
#      Store (using bootstrap_profile's temp creds from step 1) and write
#      them to ~/.aws/credentials so cookbooks downstream see
#      e.g. pve-bootstrap-ssm pre-configured.
#
# The bootstrap auth check is gated by require_external_auth — if
# bootstrap_profile auth fails on a fresh LXC, the helper auto-triggers
# `aws login --profile <bootstrap> --remote` and the operator pastes the
# auth code from a browser. On warm re-runs where all target profiles
# already read SSM successfully, skip_if shortcuts the entire dance.
#
# Defaults are configured for the home-monitor fleet (sh1admn login_session
# + pve-bootstrap-ssm SSM paths); entry recipes can override via
# node.reverse_merge! before include_cookbook "aws-credentials".
#
# Configuration shape:
#
#   node[:aws_credentials] = {
#     login_profiles: {
#       "sh1admn" => {
#         login_session: "arn:aws:iam::<acct>:user/<user>",
#         region:        "ap-northeast-1",
#       },
#     },
#     bootstrap_profile: "sh1admn",
#     profiles: {
#       "pve-bootstrap-ssm" => {
#         access_key_id_ssm:     "/home-monitor/iam/pve-bootstrap-ssm/access-key-id",
#         secret_access_key_ssm: "/home-monitor/iam/pve-bootstrap-ssm/secret-access-key",
#         region:                "ap-northeast-1",
#       },
#     },
#   }
#
# Idempotency: aws configure get checks the existing value before write;
# no rewrite, no rotation if the SSM value matches.

include_cookbook "awscli"

# login_profiles default: home-monitor sh1admn admin. login_session ARN
# is non-secret (identifies the IAM principal backing aws login --remote
# device-code flow). Entry recipes can override via node.reverse_merge!.
#
# bootstrap_profile + profiles are NOT defaulted to preserve existing
# callers (e.g. lxc-dev-workstation uses env-var bootstrap without an
# explicit profile). Entry recipes that want pve-bootstrap-ssm
# bootstrapped opt in by setting both fields explicitly.
node.reverse_merge!(
  aws_credentials: {
    login_profiles: {
      "sh1admn" => {
        login_session: "arn:aws:iam::384858471975:user/sh1admin",
        region: "ap-northeast-1",
      },
    },
  }
)

login_profiles = node.dig(:aws_credentials, :login_profiles) || {}
profiles = node.dig(:aws_credentials, :profiles) || {}
bootstrap = node.dig(:aws_credentials, :bootstrap_profile)

# Stage login_session entries in ~/.aws/config AT COMPILE TIME (Ruby
# system call, NOT a queued execute resource). Necessary because the
# auth check below runs at compile time too — if login_session writing
# were queued for converge, `aws login --remote` would fire BEFORE the
# config has [profile X] and abort with "profile not found".
#
# `aws configure set login_session ARN --profile X` writes to
# ~/.aws/config and accepts non-standard keys. Idempotent at the file
# level (no diff = no rewrite). We invoke it via `system` rather than
# direct File.write because aws-cli also creates ~/.aws/ with 0700
# permissions and handles the INI format edge cases.
login_profiles.each do |profile_name, spec|
  session_arn = spec[:login_session] || spec["login_session"]
  region      = spec[:region] || spec["region"] || "ap-northeast-1"
  next unless session_arn

  # Compile-time bootstrap of aws config — ensure_awscli_installed! has
  # run from require_external_auth in earlier recipes by now, OR will
  # run again below; either way `aws` is on PATH by the time `aws login
  # --remote` would fire.
  ensure_awscli_installed!

  existing = `aws configure get login_session --profile '#{profile_name}' 2>/dev/null`.strip
  next if existing == session_arn

  MItamae.logger.info("[aws-credentials] writing login_session for profile #{profile_name} (compile time)")
  unless system("aws configure set login_session '#{session_arn}' --profile '#{profile_name}'") &&
         system("aws configure set region '#{region}' --profile '#{profile_name}'")
    raise "aws-credentials: failed to write login_session for #{profile_name}"
  end
end

return if profiles.empty?

profile_arg = bootstrap ? " --profile '#{bootstrap}'" : ""

# Probe whether bootstrap auth has the SPECIFIC permission this cookbook
# needs (ssm:GetParameter on the configured paths). `aws sts
# get-caller-identity` is insufficient because it passes for any valid
# IAM identity, while a least-privilege identity (e.g. pve-bootstrap-ssm
# in home-monitor) may have valid credentials but no ssm:GetParameter
# on the credential paths it would otherwise rotate. See
# ~/.claude/rules/infrastructure.md "IAM principal that cannot self-rotate".
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

# Skip the entire bootstrap dance on warm re-runs where every target
# profile already reads SSM successfully — saves a round-trip and avoids
# triggering aws login when nothing needs it.
warm_state_check = -> {
  profiles.all? do |profile_name, spec|
    path   = spec[:access_key_id_ssm] || spec["access_key_id_ssm"]
    region = spec[:region] || spec["region"] || "ap-northeast-1"
    next false unless path
    run_command(
      "aws ssm get-parameter --name '#{path}' " \
      "--profile '#{profile_name}' --region '#{region}' > /dev/null 2>&1",
      error: false,
    ).exit_status == 0
  end
}

# Two-stage auth: bootstrap_profile (sh1admn admin) must work for SSM
# reads. If not, require_external_auth triggers `aws login --profile
# <bootstrap> --remote` to acquire admin temp creds via the device-code
# flow. After login succeeds, the inner execute resources fetch each
# target profile's access keys (pve-bootstrap-ssm) from SSM and write
# them to ~/.aws/credentials.
require_external_auth(
  tool_name: "AWS admin (#{bootstrap || 'env-credentials'}) for fleet credential bootstrap",
  check_command: auth_probe_cmd,
  login_profile: bootstrap,
  skip_if: warm_state_check,
  instructions: "Configure #{bootstrap || 'env'} for SSM access " \
                "(or wait for `aws login --remote` prompt).",
) do
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
end
