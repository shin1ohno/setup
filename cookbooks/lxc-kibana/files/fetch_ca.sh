#!/bin/bash
# Fetch the ES cluster CA cert from SSM and stage for install into
# /data/kibana/certs/. Used in Phase 7-tls (kibana → ES over HTTPS);
# the CA cert is fetched in Phase 3b too so the bind-mount path is
# already populated when the cutover happens.
#
# Usage: fetch_ca.sh <staging_dir>

set -euo pipefail

STAGING_DIR="$1"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_PROFILE="${AWS_PROFILE:-pve-bootstrap-ssm}"

mkdir -p "${STAGING_DIR}"

aws ssm get-parameter \
    --name "/monitoring/elastic/ca/cert" \
    --query "Parameter.Value" \
    --output text \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    > "${STAGING_DIR}/ca.crt.new"
mv "${STAGING_DIR}/ca.crt.new" "${STAGING_DIR}/ca.crt"
chmod 644 "${STAGING_DIR}/ca.crt"
