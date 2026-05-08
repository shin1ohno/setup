#!/bin/bash
# Fetch ES TLS material from SSM and stage into a temp dir for install
# into /data/elasticsearch/certs/ by mitamae.
#
# Phase 1b SSM layout (home-monitor terraform):
#   /monitoring/elastic/ca/cert                 — public CA cert (PEM, String)
#   /monitoring/elastic/nodes/<node>/cert       — node cert (PEM, String)
#   /monitoring/elastic/nodes/<node>/key        — node priv key (PEM, SecureString)
#
# Usage: fetch_certs.sh <staging_dir> <node_name>

set -euo pipefail

STAGING_DIR="$1"
NODE_NAME="$2"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_PROFILE="${AWS_PROFILE:-pve-bootstrap-ssm}"

fetch_ssm() {
    local param_path="$1"
    aws ssm get-parameter \
        --name "${param_path}" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}" 2>/dev/null \
        || { echo "SSM_FETCH_FAILED:${param_path}" >&2; return 1; }
}

mkdir -p "${STAGING_DIR}"

# CA cert — same on every ES node.
fetch_ssm "/monitoring/elastic/ca/cert" > "${STAGING_DIR}/ca.crt.new"
mv "${STAGING_DIR}/ca.crt.new" "${STAGING_DIR}/ca.crt"
chmod 644 "${STAGING_DIR}/ca.crt"

# Node cert — per-node SAN.
fetch_ssm "/monitoring/elastic/nodes/${NODE_NAME}/cert" > "${STAGING_DIR}/${NODE_NAME}.crt.new"
mv "${STAGING_DIR}/${NODE_NAME}.crt.new" "${STAGING_DIR}/${NODE_NAME}.crt"
chmod 644 "${STAGING_DIR}/${NODE_NAME}.crt"

# Node key — secret, mode 0600.
fetch_ssm "/monitoring/elastic/nodes/${NODE_NAME}/key" > "${STAGING_DIR}/${NODE_NAME}.key.new"
mv "${STAGING_DIR}/${NODE_NAME}.key.new" "${STAGING_DIR}/${NODE_NAME}.key"
chmod 600 "${STAGING_DIR}/${NODE_NAME}.key"
