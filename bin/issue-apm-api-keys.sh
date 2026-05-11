#!/bin/bash
# Issue per-service Elastic API keys for APM trace ingestion and store
# the base64-encoded forms in SSM /monitoring/apm/api-keys/<svc>.
#
# Phase 3 of the standalone APM Server plan
# (~/.claude/plans/scalable-noodling-pearl.md). The 5 home-fleet
# services use these keys as `Authorization: ApiKey <encoded>` headers
# on OTLP traffic to apm-server.home.local:8200.
#
# Per-service keys (vs a single shared secret_token) localize the
# rotation blast radius — if cognee's auth-proxy is compromised, only
# its key needs invalidation; the other 4 keep running.
#
# Idempotency: this script is NOT idempotent. Re-running creates new
# API keys with new IDs (Elastic does not deduplicate by name), leaving
# the old ones live but orphaned. Manual cleanup via:
#   curl -sk -u elastic:<pw> -X DELETE \
#     https://es-0.home.local:9200/_security/api_key \
#     -H 'Content-Type: application/json' \
#     -d '{"ids":["<old-id>"]}'
# Use `aws ssm get-parameters-by-path --path /monitoring/apm/api-keys/`
# to list current SSM-recorded keys before re-running.

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_PROFILE="${AWS_PROFILE:-sh1admn}"
ES_URL="${ES_URL:-https://es-0.home.local:9200}"

# Services that will send OTLP — keep in sync with the 5 OTel-instrumented
# services in Phases 4 and 5 of the plan.
SERVICES=(
  weave-server
  edge-agent
  roon-mcp
  cognee-auth-proxy
  ai-memory-auth-proxy
)

# Role descriptor for APM ingestion: Elastic APM uses the
# `application: apm` privilege model, NOT raw index privileges. The
# magic privilege is `event:write` — without it apm-server's
# `/intake/v2/events` returns 401 even when the key authenticates
# successfully at the cluster level. Index-level privileges (auto_configure,
# create_doc on traces-apm-*) are not what apm-server checks for intake.
#
# Reference: Elastic docs "Use API keys to authorize APM agent
# communication" — the role_descriptor shape is exactly this single
# application block.
ROLE_DESCRIPTOR=$(cat <<'JSON'
{
  "apm_writer": {
    "applications": [
      {
        "application": "apm",
        "privileges": ["event:write"],
        "resources": ["*"]
      }
    ]
  }
}
JSON
)

# Fetch the elastic superuser password from SSM (managed by home-monitor
# Terraform random_password.es_role["elastic"]).
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

put_ssm() {
    local param_path="$1"
    local value="$2"
    aws ssm put-parameter \
        --name "${param_path}" \
        --type SecureString \
        --value "${value}" \
        --overwrite \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}" \
        --query 'Tier' --output text
}

echo "[issue-apm-api-keys] fetching elastic password from SSM"
ELASTIC_PW=$(fetch_ssm "/monitoring/elastic/elastic-password")

# Issue + persist each key.
for svc in "${SERVICES[@]}"; do
    echo "[issue-apm-api-keys] issuing key for ${svc}"

    body=$(jq -nc \
        --arg name "apm-${svc}" \
        --argjson rd "${ROLE_DESCRIPTOR}" \
        '{name: $name, role_descriptors: $rd}')

    resp=$(curl -fsSk -u "elastic:${ELASTIC_PW}" \
        -X POST "${ES_URL}/_security/api_key" \
        -H 'Content-Type: application/json' \
        -d "${body}")

    id=$(echo "${resp}" | jq -r '.id')
    encoded=$(echo "${resp}" | jq -r '.encoded')

    if [[ -z "${id}" || -z "${encoded}" || "${encoded}" == "null" ]]; then
        echo "[issue-apm-api-keys] FAILED for ${svc} — response:" >&2
        echo "${resp}" >&2
        exit 1
    fi

    echo "[issue-apm-api-keys]   id=${id}"
    tier=$(put_ssm "/monitoring/apm/api-keys/${svc}" "${encoded}")
    echo "[issue-apm-api-keys]   SSM put at /monitoring/apm/api-keys/${svc} (tier=${tier})"
done

echo "[issue-apm-api-keys] all 5 keys issued + persisted"
echo "[issue-apm-api-keys] verify:"
echo "  for svc in ${SERVICES[*]}; do"
echo "    aws ssm get-parameter --region ${AWS_REGION} --profile ${AWS_PROFILE} \\"
echo "      --name \"/monitoring/apm/api-keys/\${svc}\" --with-decryption \\"
echo "      --query 'Parameter.Value' --output text | head -c 32"
echo "    echo \" <- \${svc}\""
echo "  done"
