#!/usr/bin/env bash
# Phase 7-s3 — Elasticsearch S3 snapshot bootstrap (NATIVE INSTALL VARIANT).
#
# Adapted from docs/adr/0005-impl/phase-7-s3-cookbook.patch which targeted
# the docker-based ES install. Phase 3b shipped native systemd ES instead,
# so this script:
#   - calls /usr/share/elasticsearch/bin/elasticsearch-keystore directly
#     (no `docker exec`)
#   - reads ELASTIC_PASSWORD from /etc/elasticsearch/elasticsearch-secrets.env
#     (Phase 3b naming)
#   - hits http://localhost:9200 (Phase 7-tls migration ships separately
#     in PR #240)
#
# Subcommands:
#   keystore-add             Fetch S3 creds from SSM, hash-compare against
#                            sentinel, re-add to ES keystore if changed.
#   reload-secure-settings   POST /_nodes/reload_secure_settings on local node.
#   register-repo            PUT /_snapshot/s3-home-monitor (idempotent).
#   repo-exists              Exit 0 if repo already registered.
#   register-slm             PUT /_slm/policy/daily-snapshot (idempotent).
#   slm-exists               Exit 0 if SLM policy already registered.
#
# Env (passed by mitamae execute):
#   AWS_PROFILE, AWS_REGION

set -euo pipefail

ENV_FILE="${ES_ENV_FILE:-/etc/elasticsearch/elasticsearch-secrets.env}"
KEYSTORE_BIN="/usr/share/elasticsearch/bin/elasticsearch-keystore"
SENTINEL="/var/lib/elasticsearch/.s3-keystore-hash"
BUCKET_FILE="/var/lib/elasticsearch/.s3-bucket"
REPO_NAME="s3-home-monitor"
SLM_POLICY="daily-snapshot"
ES_URL="${ES_URL:-http://localhost:9200}"

SSM_ACCESS_KEY_PATH="/monitoring/elastic/s3-snapshot/access-key-id"
SSM_SECRET_KEY_PATH="/monitoring/elastic/s3-snapshot/secret-access-key"
SSM_BUCKET_PATH="/monitoring/elastic/s3-snapshot/bucket-name"

# elasticsearch-secrets.env contains literal KEY=VALUE pairs; sourcing it
# directly fails if values contain shell metacharacters (the ELASTIC_PASSWORD
# regularly does — see elastic-agent .env handling). Parse manually with awk.
ELASTIC_PASSWORD="$(awk -F= '/^ELASTIC_PASSWORD=/{ sub(/^ELASTIC_PASSWORD=/,""); print; exit }' "${ENV_FILE}")"
: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD missing from ${ENV_FILE}}"

ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    --output text --query 'Parameter.Value'
}

es_curl() {
  curl -fsS -u "elastic:${ELASTIC_PASSWORD}" "$@"
}

es_curl_status() {
  curl -s -o /dev/null -w '%{http_code}' \
    -u "elastic:${ELASTIC_PASSWORD}" "$@"
}

ks_add() {
  # Run as root: /etc/elasticsearch/ is drwxr-s--- root:elasticsearch on
  # the DEB install — only root can write. The keystore binary itself
  # respects the existing file ownership/group permissions.
  local setting="$1" value="$2"
  printf '%s' "${value}" | "${KEYSTORE_BIN}" add --stdin --force "${setting}"
}

cmd_keystore_add() {
  local access_key secret_key bucket combined hash

  access_key=$(ssm_get "${SSM_ACCESS_KEY_PATH}")
  secret_key=$(ssm_get "${SSM_SECRET_KEY_PATH}")
  bucket=$(ssm_get "${SSM_BUCKET_PATH}")

  combined="${access_key}|${secret_key}|${bucket}"
  hash=$(printf '%s' "${combined}" | openssl dgst -sha256 | awk '{print $2}')

  if [[ -f "${SENTINEL}" ]] && [[ "$(cat "${SENTINEL}")" == "${hash}" ]]; then
    echo "[s3-snapshot] keystore in sync (hash matches sentinel) — skipping"
    return 0
  fi

  echo "[s3-snapshot] adding S3 access key to ES keystore"
  ks_add s3.client.default.access_key "${access_key}"

  echo "[s3-snapshot] adding S3 secret key to ES keystore"
  ks_add s3.client.default.secret_key "${secret_key}"

  install -d -m 700 -o root -g root /var/lib/elasticsearch
  printf '%s' "${bucket}" > "${BUCKET_FILE}"
  chmod 600 "${BUCKET_FILE}"

  printf '%s' "${hash}" > "${SENTINEL}"
  chmod 600 "${SENTINEL}"

  echo "[s3-snapshot] keystore add complete; sentinel updated"
}

cmd_reload_secure_settings() {
  echo "[s3-snapshot] reloading secure settings (local node)"
  es_curl -X POST "${ES_URL}/_nodes/reload_secure_settings" \
    -H 'Content-Type: application/json' \
    -d '{"secure_settings_password":""}' >/dev/null
  echo "[s3-snapshot] reload OK"
}

cmd_repo_exists() {
  # GET /_snapshot/<name>/_status returns 200 even when the repo does
  # not exist (it answers "no snapshot in progress" without checking
  # repo registration). Use GET /_snapshot/<name> instead — that
  # returns 404 for unknown repos.
  local status
  status=$(es_curl_status "${ES_URL}/_snapshot/${REPO_NAME}" || true)
  [[ "${status}" == "200" ]]
}

cmd_register_repo() {
  local bucket

  if [[ ! -f "${BUCKET_FILE}" ]]; then
    echo "[s3-snapshot] ERROR: bucket name not staged; run keystore-add first" >&2
    exit 1
  fi
  bucket=$(cat "${BUCKET_FILE}")

  if cmd_repo_exists; then
    echo "[s3-snapshot] repo ${REPO_NAME} already registered — skipping"
    return 0
  fi

  echo "[s3-snapshot] registering snapshot repo ${REPO_NAME} (bucket=${bucket})"
  es_curl -X PUT "${ES_URL}/_snapshot/${REPO_NAME}" \
    -H 'Content-Type: application/json' \
    -d @- >/dev/null <<EOF
{
  "type": "s3",
  "settings": {
    "bucket": "${bucket}",
    "base_path": "snapshots/home-monitor-rtx",
    "client": "default",
    "compress": true
  }
}
EOF
  echo "[s3-snapshot] repo registered"
}

cmd_slm_exists() {
  local status
  status=$(es_curl_status "${ES_URL}/_slm/policy/${SLM_POLICY}" || true)
  [[ "${status}" == "200" ]]
}

cmd_register_slm() {
  if cmd_slm_exists; then
    echo "[s3-snapshot] SLM ${SLM_POLICY} already exists — skipping"
    return 0
  fi

  echo "[s3-snapshot] registering SLM policy ${SLM_POLICY}"
  es_curl -X PUT "${ES_URL}/_slm/policy/${SLM_POLICY}" \
    -H 'Content-Type: application/json' \
    -d @- >/dev/null <<'EOF'
{
  "schedule": "0 30 1 * * ?",
  "name": "<daily-snap-{now/d}>",
  "repository": "s3-home-monitor",
  "config": {
    "indices": ["logs-rtx-*", "synthetics-*", "metrics-system.*"],
    "include_global_state": false,
    "ignore_unavailable": true
  },
  "retention": {
    "expire_after": "30d",
    "min_count": 7,
    "max_count": 30
  }
}
EOF
  echo "[s3-snapshot] SLM policy registered"
}

main() {
  case "${1:-}" in
    keystore-add)            cmd_keystore_add ;;
    reload-secure-settings)  cmd_reload_secure_settings ;;
    register-repo)           cmd_register_repo ;;
    repo-exists)             cmd_repo_exists ;;
    register-slm)            cmd_register_slm ;;
    slm-exists)              cmd_slm_exists ;;
    *)
      echo "usage: $0 {keystore-add|reload-secure-settings|register-repo|repo-exists|register-slm|slm-exists}" >&2
      exit 64
      ;;
  esac
}

main "$@"
