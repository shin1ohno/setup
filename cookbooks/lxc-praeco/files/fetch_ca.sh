#!/bin/bash
# Fetch the ES cluster CA cert from SSM and stage for install into
# /root/deploy/praeco/certs/. ES HTTP TLS is enabled cluster-wide
# (Phase 7-tls PR #307), so praeco/elastalert-server must trust the CA
# to talk to https://es-{0,1,2}.home.local:9200.
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
