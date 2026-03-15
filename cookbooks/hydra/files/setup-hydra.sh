#!/bin/bash
# Full Hydra setup: SSM parameters, Aurora user/DB, and Google OAuth client
#
# Prerequisites:
#   - gcloud CLI installed (`gcloud auth login` for Google OAuth)
#   - aws CLI configured with SSM and Aurora access
#   - psql available (or Docker for ephemeral postgres client)
#
# Usage:
#   bash setup-hydra.sh [GOOGLE_PROJECT_ID]

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

echo "╔══════════════════════════════════════════════════╗"
echo "║          Hydra Initial Setup                     ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Helper: put SSM parameter (skip if already exists) ─────────────────

put_ssm() {
  local name="$1" value="$2" description="${3:-}"
  if aws ssm get-parameter --name "${name}" --region "${AWS_REGION}" &>/dev/null; then
    echo "  ${name} already exists, skipping (use --overwrite manually to update)"
  else
    aws ssm put-parameter \
      --name "${name}" \
      --type SecureString \
      --value "${value}" \
      --description "${description}" \
      --region "${AWS_REGION}" \
      --no-cli-pager >/dev/null
    echo "  ${name} ✓"
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# Part 1: Hydra core SSM parameters
# ══════════════════════════════════════════════════════════════════════════

echo "── Part 1: Hydra core parameters ──"
echo ""

# /hydra/system-secret — auto-generate 32-byte random secret
SYSTEM_SECRET=$(openssl rand -base64 32)
echo "[1/3] Hydra system secret (auto-generated)"
put_ssm "/hydra/system-secret" "${SYSTEM_SECRET}" "Hydra SECRETS_SYSTEM"

# /hydra/aurora-password — auto-generate
AURORA_PASSWORD=$(openssl rand -base64 24 | tr -d '/@"'"'"' ')
echo "[2/3] Aurora password for hydra user (auto-generated)"
put_ssm "/hydra/aurora-password" "${AURORA_PASSWORD}" "Aurora password for hydra DB user"

# /hydra/allowed-emails — prompt
echo "[3/3] Allowed emails for consent app login"
EXISTING_EMAILS=$(aws ssm get-parameter --name "/hydra/allowed-emails" --region "${AWS_REGION}" --with-decryption --query "Parameter.Value" --output text 2>/dev/null || true)
if [ -n "${EXISTING_EMAILS}" ]; then
  echo "  /hydra/allowed-emails already exists: ${EXISTING_EMAILS}"
  echo ""
  read -rp "  Update? [y/N]: " UPDATE_EMAILS
  if [[ "${UPDATE_EMAILS}" =~ ^[Yy]$ ]]; then
    read -rp "  Enter allowed emails (comma-separated): " ALLOWED_EMAILS
    aws ssm put-parameter \
      --name "/hydra/allowed-emails" \
      --type SecureString \
      --value "${ALLOWED_EMAILS}" \
      --overwrite \
      --region "${AWS_REGION}" \
      --no-cli-pager >/dev/null
    echo "  /hydra/allowed-emails updated ✓"
  fi
else
  read -rp "  Enter allowed emails (comma-separated): " ALLOWED_EMAILS
  put_ssm "/hydra/allowed-emails" "${ALLOWED_EMAILS}" "Comma-separated emails allowed to log in"
fi

echo ""
echo "── Part 1 complete ──"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# Part 2: Aurora user and database
# ══════════════════════════════════════════════════════════════════════════

echo "── Part 2: Aurora hydra user/database ──"
echo ""

AURORA_ENDPOINT=$(aws ssm get-parameter --name "/memory/aurora-endpoint" --region "${AWS_REGION}" --with-decryption --query "Parameter.Value" --output text 2>/dev/null || true)

if [ -z "${AURORA_ENDPOINT}" ]; then
  echo "  /memory/aurora-endpoint not found in SSM."
  read -rp "  Enter Aurora endpoint: " AURORA_ENDPOINT
fi

echo "  Aurora endpoint: ${AURORA_ENDPOINT}"

# Retrieve the password we just stored (or existing one)
HYDRA_PASSWORD=$(aws ssm get-parameter --name "/hydra/aurora-password" --region "${AWS_REGION}" --with-decryption --query "Parameter.Value" --output text)

echo "  Creating user and database (requires Aurora admin access)..."
echo ""
echo "  If you have psql with admin credentials, run:"
echo ""
echo "    psql \"postgresql://admin_user:admin_pass@${AURORA_ENDPOINT}:5432/postgres?sslmode=require\""
echo ""
echo "    CREATE USER hydra WITH PASSWORD '${HYDRA_PASSWORD}';"
echo "    CREATE DATABASE hydra OWNER hydra;"
echo ""

read -rp "  Attempt auto-creation via Docker? (needs admin DB URL) [y/N]: " AUTO_CREATE

if [[ "${AUTO_CREATE}" =~ ^[Yy]$ ]]; then
  read -rp "  Enter Aurora admin connection string (postgresql://user:pass@host:5432/postgres?sslmode=require): " ADMIN_DSN

  docker run --rm postgres:16-alpine sh -c "
    psql '${ADMIN_DSN}' -c \"DO \\\$\\\$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hydra') THEN
        CREATE USER hydra WITH PASSWORD '${HYDRA_PASSWORD}';
      END IF;
    END \\\$\\\$;\"
    psql '${ADMIN_DSN}' -c \"SELECT 1 FROM pg_database WHERE datname = 'hydra'\" | grep -q 1 || \
    psql '${ADMIN_DSN}' -c \"CREATE DATABASE hydra OWNER hydra;\"
  "
  echo "  Aurora user and database created ✓"
else
  echo "  Skipping auto-creation. Please create manually before deploying."
fi

echo ""
echo "── Part 2 complete ──"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# Part 3: Google OAuth client
# ══════════════════════════════════════════════════════════════════════════

echo "── Part 3: Google OAuth client ──"
echo ""

# Check if already configured
EXISTING_GID=$(aws ssm get-parameter --name "/hydra/google-client-id" --region "${AWS_REGION}" --query "Parameter.Value" --output text --with-decryption 2>/dev/null || true)
if [ -n "${EXISTING_GID}" ]; then
  echo "  /hydra/google-client-id already exists: ${EXISTING_GID:0:20}..."
  read -rp "  Reconfigure Google OAuth? [y/N]: " RECONFIG_GOOGLE
  if ! [[ "${RECONFIG_GOOGLE}" =~ ^[Yy]$ ]]; then
    echo "  Skipping Google OAuth setup."
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║          Setup Complete                          ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo "SSM parameters:"
    echo "  /hydra/system-secret"
    echo "  /hydra/aurora-password"
    echo "  /hydra/allowed-emails"
    echo "  /hydra/google-client-id"
    echo "  /hydra/google-client-secret"
    echo ""
    echo "Next: run './bin/mitamae local linux.rb' to deploy Hydra"
    exit 0
  fi
fi

# ── Select gcloud account ─────────────────────────────────────────────

mapfile -t ACCOUNTS < <(gcloud auth list --format="value(account)" 2>/dev/null)

if [ ${#ACCOUNTS[@]} -eq 0 ]; then
  echo "  No gcloud accounts found. Please run 'gcloud auth login' first."
  exit 1
fi

echo "  Authenticated gcloud accounts:"
echo ""
for i in "${!ACCOUNTS[@]}"; do
  echo "    $((i + 1))) ${ACCOUNTS[$i]}"
done
NEW_LOGIN_INDEX=$(( ${#ACCOUNTS[@]} + 1 ))
echo "    ${NEW_LOGIN_INDEX}) Log in with a different account"
echo ""

read -rp "  Select account [1-${NEW_LOGIN_INDEX}]: " ACCOUNT_INDEX

if ! [[ "${ACCOUNT_INDEX}" =~ ^[0-9]+$ ]] || [ "${ACCOUNT_INDEX}" -lt 1 ] || [ "${ACCOUNT_INDEX}" -gt "${NEW_LOGIN_INDEX}" ]; then
  echo "Invalid selection."
  exit 1
fi

if [ "${ACCOUNT_INDEX}" -eq "${NEW_LOGIN_INDEX}" ]; then
  echo ""
  gcloud auth login --no-launch-browser
  SELECTED_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
else
  SELECTED_ACCOUNT="${ACCOUNTS[$((ACCOUNT_INDEX - 1))]}"
  gcloud config set account "${SELECTED_ACCOUNT}" 2>/dev/null
fi
echo ""
echo "  Using account: ${SELECTED_ACCOUNT}"
echo ""

# ── Google Cloud project ───────────────────────────────────────────────

GOOGLE_PROJECT_ID="${1:-hydra-oauth-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
REDIRECT_URI="https://mcp.ohno.be/consent/google/callback"

echo "  Project ID:    ${GOOGLE_PROJECT_ID}"
echo "  Redirect URI:  ${REDIRECT_URI}"
echo ""

if gcloud projects describe "${GOOGLE_PROJECT_ID}" &>/dev/null; then
  echo "  [a] Project '${GOOGLE_PROJECT_ID}' already exists, skipping"
else
  echo "  [a] Creating project '${GOOGLE_PROJECT_ID}'..."
  gcloud projects create "${GOOGLE_PROJECT_ID}" --name="Hydra OAuth"
  echo "      Done ✓"
fi

gcloud config set project "${GOOGLE_PROJECT_ID}"

echo "  [b] Enabling APIs..."
gcloud services enable people.googleapis.com --quiet 2>/dev/null || true
echo "      Done ✓"

# ── OAuth consent screen + client (Console) ────────────────────────────

echo "  [c] Create OAuth consent screen and client in Google Cloud Console."
echo ""
echo "      1. Open: https://console.cloud.google.com/apis/credentials/consent?project=${GOOGLE_PROJECT_ID}"
echo "         - User Type: External → Create"
echo "         - App name: Hydra Consent"
echo "         - User support email: ${SELECTED_ACCOUNT}"
echo "         - Developer contact email: ${SELECTED_ACCOUNT}"
echo "         - Save and Continue (skip Scopes, Test users)"
echo ""
echo "      2. Open: https://console.cloud.google.com/apis/credentials?project=${GOOGLE_PROJECT_ID}"
echo "         - Create Credentials → OAuth client ID"
echo "         - Application type: Web application"
echo "         - Name: Hydra Consent App"
echo "         - Authorized redirect URIs: ${REDIRECT_URI}"
echo "         - Click Create"
echo ""

read -rp "      Enter Client ID: " CLIENT_ID
read -rp "      Enter Client Secret: " CLIENT_SECRET
echo "      Done ✓"

# ── Store Google OAuth in SSM ──────────────────────────────────────────

echo "  [e] Storing in SSM..."

aws ssm put-parameter \
  --name "/hydra/google-client-id" \
  --type SecureString \
  --value "${CLIENT_ID}" \
  --overwrite \
  --region "${AWS_REGION}" \
  --no-cli-pager >/dev/null
echo "      /hydra/google-client-id ✓"

aws ssm put-parameter \
  --name "/hydra/google-client-secret" \
  --type SecureString \
  --value "${CLIENT_SECRET}" \
  --overwrite \
  --region "${AWS_REGION}" \
  --no-cli-pager >/dev/null
echo "      /hydra/google-client-secret ✓"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          Setup Complete                          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "SSM parameters:"
echo "  /hydra/system-secret"
echo "  /hydra/aurora-password"
echo "  /hydra/allowed-emails"
echo "  /hydra/google-client-id"
echo "  /hydra/google-client-secret"
echo ""
echo "Google Cloud project: ${GOOGLE_PROJECT_ID}"
echo "Console: https://console.cloud.google.com/apis/credentials?project=${GOOGLE_PROJECT_ID}"
echo ""
echo "Next: run './bin/mitamae local linux.rb' to deploy Hydra"
