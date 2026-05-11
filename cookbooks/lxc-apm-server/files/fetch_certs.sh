#!/bin/bash
# Fetch APM Server TLS cert + key + CA from SSM and stage for install
# into /etc/apm-server/certs/. The Terraform-managed certs are signed
# by the same internal CA as the ES cluster (tls_self_signed_cert.es_ca)
# so the cookbook only needs to fetch from /monitoring/apm/* — no need
# to deal with /monitoring/elastic/ca/cert separately.
#
# Usage: fetch_certs.sh <staging_dir>

set -euo pipefail

STAGING_DIR="$1"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_PROFILE="${AWS_PROFILE:-pve-bootstrap-ssm}"

mkdir -p "${STAGING_DIR}"

fetch_ssm() {
    local param_path="$1"
    aws ssm get-parameter \
        --name "${param_path}" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}"
}

# Atomic write — fetch to .new, then mv. Prevents readers from picking
# up a half-written cert on a re-fetch.
fetch_ssm "/monitoring/apm/server/cert" > "${STAGING_DIR}/server.crt.new"
fetch_ssm "/monitoring/apm/server/key"  > "${STAGING_DIR}/server.key.new"
fetch_ssm "/monitoring/apm/ca/cert"     > "${STAGING_DIR}/ca.crt.new"

mv "${STAGING_DIR}/server.crt.new" "${STAGING_DIR}/server.crt"
mv "${STAGING_DIR}/server.key.new" "${STAGING_DIR}/server.key"
mv "${STAGING_DIR}/ca.crt.new"     "${STAGING_DIR}/ca.crt"

chmod 644 "${STAGING_DIR}/server.crt" "${STAGING_DIR}/ca.crt"
chmod 600 "${STAGING_DIR}/server.key"
