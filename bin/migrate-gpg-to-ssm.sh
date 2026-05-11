#!/usr/bin/env bash
#
# migrate-gpg-to-ssm.sh
#
# One-shot migration: copy GPG backup secrets from AWS Secrets Manager
# to AWS SSM Parameter Store, ready to be consumed by the new
# gpg-master-backup cookbook (cookbooks/gpg-backup/default.rb).
#
# After running this script and verifying read access via the new
# cookbook, delete the source secrets manually:
#
#   aws secretsmanager delete-secret \
#     --secret-id <name> --recovery-window-in-days 7 \
#     --profile sh1admn --region ap-northeast-1
#
# The 7-day recovery window is the safety net; it permanently disappears
# 7 days after the call.
#

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-sh1admn}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SSM_PREFIX="/gpg"

SECRETS=(
    "gpg-master-key/BF70703A832AF6C9"
    "gpg-ownertrust"
    "gpg-subkeys/BF70703A832AF6C9"
    "gpg-master-key/B29CA35049668DEE"
)

log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() { log_error "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

main() {
    require_cmd aws

    log_info "Verifying AWS credentials (profile=${AWS_PROFILE}, region=${AWS_REGION})"
    aws sts get-caller-identity --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
        >/dev/null || die "AWS credentials check failed"

    for secret_name in "${SECRETS[@]}"; do
        local ssm_path="${SSM_PREFIX}/${secret_name}"

        log_info "Reading source: ${secret_name}"
        local value
        if ! value=$(aws secretsmanager get-secret-value \
            --secret-id "${secret_name}" \
            --query 'SecretString' \
            --output text \
            --profile "${AWS_PROFILE}" \
            --region "${AWS_REGION}" 2>/dev/null); then
            log_warn "Source secret not found, skipping: ${secret_name}"
            continue
        fi

        local size=${#value}
        local tier="Standard"
        if [[ ${size} -gt 4096 ]]; then
            tier="Advanced"
            log_warn "Payload ${size} bytes > 4096 — using Advanced tier (\$0.05/month) for ${ssm_path}"
        else
            log_info "Payload ${size} bytes — using Standard tier (free) for ${ssm_path}"
        fi

        log_info "Writing target: ${ssm_path}"
        aws ssm put-parameter \
            --name "${ssm_path}" \
            --type SecureString \
            --value "${value}" \
            --description "Migrated from Secrets Manager: ${secret_name}" \
            --tier "${tier}" \
            --overwrite \
            --profile "${AWS_PROFILE}" \
            --region "${AWS_REGION}" \
            --output text >/dev/null

        # Verify round-trip
        local roundtrip
        roundtrip=$(aws ssm get-parameter \
            --name "${ssm_path}" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --profile "${AWS_PROFILE}" \
            --region "${AWS_REGION}")

        if [[ "${roundtrip}" == "${value}" ]]; then
            log_info "Round-trip OK: ${ssm_path}"
        else
            die "Round-trip MISMATCH for ${ssm_path} — source ${#value} bytes vs target ${#roundtrip} bytes"
        fi
    done

    log_info ""
    log_info "Migration complete."
    log_info ""
    log_info "Next steps:"
    log_info "  1. Test gpg-master-backup list / restore on a host with the new cookbook applied."
    log_info "  2. Once verified, delete source secrets with --recovery-window-in-days 7:"
    log_info ""
    for secret_name in "${SECRETS[@]}"; do
        log_info "       aws secretsmanager delete-secret \\"
        log_info "         --secret-id '${secret_name}' \\"
        log_info "         --recovery-window-in-days 7 \\"
        log_info "         --profile '${AWS_PROFILE}' --region '${AWS_REGION}'"
    done
}

main "$@"
