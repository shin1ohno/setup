#!/bin/bash
# Fetch MCP prober credentials from SSM and emit an env file that
# mcp-probe.service consumes via EnvironmentFile=. Caller passes the
# output path as $1 (cookbook stages it under node[:setup][:root]/generated
# and then sudo-installs to /etc/mcp-probe/probe.env).
#
# Required env on entry:
#   AWS_PROFILE / AWS_REGION (or default credential chain)
#
# Required SSM parameters (provisioned by cookbooks/hydra-server when the
# monitoring-prober Hydra client is registered):
#   /monitoring/mcp-prober-client-id     (String)
#   /monitoring/mcp-prober-client-secret (SecureString)

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-env-file>" >&2
  exit 1
fi

out="$1"
umask 077

CID=$(aws ssm get-parameter \
  --name /monitoring/mcp-prober-client-id \
  --query Parameter.Value --output text)
CSEC=$(aws ssm get-parameter \
  --name /monitoring/mcp-prober-client-secret \
  --with-decryption --query Parameter.Value --output text)

cat > "$out" <<EOF
PROBER_CLIENT_ID=${CID}
PROBER_CLIENT_SECRET=${CSEC}
HYDRA_TOKEN_URL=http://192.168.1.71:4444/oauth2/token
MCP_BASE_URL=https://mcp.ohno.be
TEXTFILE_OUT=/var/lib/node_exporter/textfile_collector/mcp_probe.prom
PROBE_TIMEOUT_S=15
EOF

chmod 600 "$out"
