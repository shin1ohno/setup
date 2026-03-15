#!/bin/bash
# Setup Google OAuth client for Hydra consent app
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)
#   - aws CLI configured with SSM access
#
# Usage:
#   bash setup-google-oauth.sh [PROJECT_ID]
#
# If PROJECT_ID is omitted, defaults to "hydra-oauth-<random>"

set -euo pipefail

# ── 0. Select gcloud account ───────────────────────────────────────────

echo "=== Google OAuth Setup for Hydra Consent App ==="
echo ""

# Get all authenticated accounts
mapfile -t ACCOUNTS < <(gcloud auth list --format="value(account)" 2>/dev/null)

if [ ${#ACCOUNTS[@]} -eq 0 ]; then
  echo "No gcloud accounts found. Please run 'gcloud auth login' first."
  exit 1
fi

echo "Authenticated gcloud accounts:"
echo ""
for i in "${!ACCOUNTS[@]}"; do
  echo "  $((i + 1))) ${ACCOUNTS[$i]}"
done
echo ""

read -rp "Select account [1-${#ACCOUNTS[@]}]: " ACCOUNT_INDEX

if ! [[ "${ACCOUNT_INDEX}" =~ ^[0-9]+$ ]] || [ "${ACCOUNT_INDEX}" -lt 1 ] || [ "${ACCOUNT_INDEX}" -gt ${#ACCOUNTS[@]} ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED_ACCOUNT="${ACCOUNTS[$((ACCOUNT_INDEX - 1))]}"
gcloud config set account "${SELECTED_ACCOUNT}" 2>/dev/null
echo ""
echo "Using account: ${SELECTED_ACCOUNT}"
echo ""

# ── Setup variables ────────────────────────────────────────────────────

PROJECT_ID="${1:-hydra-oauth-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
REDIRECT_URI="https://mcp.ohno.be/consent/google/callback"
SUPPORT_EMAIL="${SELECTED_ACCOUNT}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

echo "Project ID:    ${PROJECT_ID}"
echo "Redirect URI:  ${REDIRECT_URI}"
echo "Support Email: ${SUPPORT_EMAIL}"
echo ""

# ── 1. Create project (if not exists) ──────────────────────────────────

if gcloud projects describe "${PROJECT_ID}" &>/dev/null; then
  echo "[1/5] Project '${PROJECT_ID}' already exists, skipping"
else
  echo "[1/5] Creating project '${PROJECT_ID}'..."
  gcloud projects create "${PROJECT_ID}" --name="Hydra OAuth"
fi

gcloud config set project "${PROJECT_ID}"

# ── 2. Enable required APIs ────────────────────────────────────────────

echo "[2/5] Enabling APIs..."
gcloud services enable iap.googleapis.com --quiet 2>/dev/null || true
gcloud services enable people.googleapis.com --quiet 2>/dev/null || true

# ── 3. Configure OAuth consent screen ──────────────────────────────────

echo "[3/5] Configuring OAuth consent screen..."

ACCESS_TOKEN="$(gcloud auth print-access-token)"

# Check if brand already exists
EXISTING_BRAND=$(curl -sf \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://iap.googleapis.com/v1/projects/${PROJECT_ID}/brands" \
  | python3 -c "import sys,json; brands=json.load(sys.stdin).get('brands',[]); print(brands[0]['name'] if brands else '')" 2>/dev/null || true)

if [ -n "${EXISTING_BRAND}" ]; then
  echo "  OAuth consent screen already configured"
  BRAND_NAME="${EXISTING_BRAND}"
else
  BRAND_RESPONSE=$(curl -sf \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"applicationTitle\": \"Hydra Consent\",
      \"supportEmail\": \"${SUPPORT_EMAIL}\"
    }" \
    "https://iap.googleapis.com/v1/projects/${PROJECT_ID}/brands")

  BRAND_NAME=$(echo "${BRAND_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
  echo "  Created: ${BRAND_NAME}"
fi

# ── 4. Create OAuth client ─────────────────────────────────────────────

echo "[4/5] Creating OAuth client..."

# The IAP API doesn't support redirect URIs, so we use the Cloud Console API
# to create a standard OAuth 2.0 web client.

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")

# List existing clients to check for duplicates
EXISTING_CLIENTS=$(curl -sf \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://oauth2.googleapis.com/v2/projects/${PROJECT_NUMBER}/oauthClients" 2>/dev/null || echo '{}')

EXISTING_CLIENT_ID=$(echo "${EXISTING_CLIENTS}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('oauthClients', []):
    if c.get('displayName') == 'Hydra Consent App':
        # Client ID is in the name field
        print(c.get('clientId', ''))
        break
" 2>/dev/null || true)

if [ -n "${EXISTING_CLIENT_ID}" ]; then
  echo "  OAuth client 'Hydra Consent App' already exists: ${EXISTING_CLIENT_ID}"
  echo ""
  echo "  If you need the client secret, retrieve it from Google Cloud Console:"
  echo "  https://console.cloud.google.com/apis/credentials?project=${PROJECT_ID}"
  echo ""
  echo "  Or delete and recreate by running this script again after removing the client."
  exit 0
fi

# Create via the standard credentials API
CLIENT_RESPONSE=$(curl -sf \
  -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"client_id\": \"\",
    \"client_secret\": \"\",
    \"redirect_uris\": [\"${REDIRECT_URI}\"],
    \"client_name\": \"Hydra Consent App\",
    \"application_type\": \"web\"
  }" \
  "https://www.googleapis.com/oauth2/v1/projects/${PROJECT_NUMBER}/oauthClients" 2>/dev/null || true)

# Fallback: use gcloud alpha if REST API isn't available
if [ -z "${CLIENT_RESPONSE}" ] || echo "${CLIENT_RESPONSE}" | grep -q '"error"'; then
  echo "  REST API not available, falling back to manual instructions..."
  echo ""
  echo "  Please create the OAuth client manually:"
  echo ""
  echo "  1. Open: https://console.cloud.google.com/apis/credentials?project=${PROJECT_ID}"
  echo "  2. Click 'Create Credentials' → 'OAuth client ID'"
  echo "  3. Application type: 'Web application'"
  echo "  4. Name: 'Hydra Consent App'"
  echo "  5. Authorized redirect URIs: ${REDIRECT_URI}"
  echo "  6. Click 'Create'"
  echo ""
  read -rp "  Enter Client ID: " CLIENT_ID
  read -rp "  Enter Client Secret: " CLIENT_SECRET
else
  CLIENT_ID=$(echo "${CLIENT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
  CLIENT_SECRET=$(echo "${CLIENT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_secret'])")
  echo "  Created OAuth client: ${CLIENT_ID}"
fi

# ── 5. Store in AWS SSM ────────────────────────────────────────────────

echo "[5/5] Storing credentials in AWS SSM..."

aws ssm put-parameter \
  --name "/hydra/google-client-id" \
  --type SecureString \
  --value "${CLIENT_ID}" \
  --overwrite \
  --region "${AWS_REGION}" \
  --no-cli-pager

aws ssm put-parameter \
  --name "/hydra/google-client-secret" \
  --type SecureString \
  --value "${CLIENT_SECRET}" \
  --overwrite \
  --region "${AWS_REGION}" \
  --no-cli-pager

echo ""
echo "=== Done ==="
echo ""
echo "Stored in SSM:"
echo "  /hydra/google-client-id"
echo "  /hydra/google-client-secret"
echo ""
echo "Project: ${PROJECT_ID}"
echo "Console: https://console.cloud.google.com/apis/credentials?project=${PROJECT_ID}"
