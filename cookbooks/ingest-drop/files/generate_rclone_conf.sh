#!/bin/bash
# Generate rclone config for ingest-drop S3 bucket from AWS SSM Parameter Store
# Usage: generate_rclone_conf.sh <output_path>
#
# Required env: AWS_PROFILE (cookbook passes it from cookbooks/ssh-keys/files/aws-config.json).
# Optional env: AWS_REGION (default: ap-northeast-1).

set -euo pipefail

OUTPUT_FILE="$1"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE must be set (cookbook reads from cookbooks/ssh-keys/files/aws-config.json)}"

fetch_ssm() {
  local param_path="$1"
  aws ssm get-parameter \
    --name "${param_path}" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" 2>/dev/null \
    || { echo "SSM_FETCH_FAILED:${param_path} (profile=${AWS_PROFILE} region=${AWS_REGION})" >&2; return 1; }
}

ACCESS_KEY_ID=$(fetch_ssm "/ingest/drop/access-key-id")
SECRET_ACCESS_KEY=$(fetch_ssm "/ingest/drop/secret-access-key")
BUCKET_NAME=$(fetch_ssm "/ingest/drop/bucket-name")
BUCKET_REGION=$(fetch_ssm "/ingest/drop/region")

cat > "${OUTPUT_FILE}" <<EOF
[ingest-drop]
type = s3
provider = AWS
access_key_id = ${ACCESS_KEY_ID}
secret_access_key = ${SECRET_ACCESS_KEY}
region = ${BUCKET_REGION}
EOF

chmod 600 "${OUTPUT_FILE}"
echo "rclone config written to ${OUTPUT_FILE}" >&2
echo "bucket = ${BUCKET_NAME}" >&2
