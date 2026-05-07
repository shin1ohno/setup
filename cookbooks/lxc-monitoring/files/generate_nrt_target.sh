#!/bin/bash
# Generate Prometheus file_sd target JSON for the nrt-subnet-router EC2.
# Usage: generate_nrt_target.sh <output_path>
#
# Reads the EC2 VPC private IP from SSM (/monitoring/nrt-private-ip,
# published by home-monitor's pve-monitoring-lxc.tf at terraform apply
# time) and writes a file_sd-formatted JSON. Prometheus picks up the
# new mtime via its file watcher; --web.enable-lifecycle is irrelevant
# for this path because file_sd_configs reload independent of HUP.
#
# Auto-mitamae's ≤30 min cycle re-runs the cookbook, which re-runs this
# script, so a new EC2 (different VPC private IP after recreation)
# propagates to the scrape target without manual intervention.
#
# AWS_PROFILE + AWS_REGION are supplied by the caller (mitamae default.rb
# sourced from cookbooks/ssh-keys/files/devices.json), matching the
# require_external_auth gate's check_command profile.

set -euo pipefail

OUTPUT_FILE="$1"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_PROFILE="${AWS_PROFILE:-pve-bootstrap-ssm}"

NRT_IP=$(aws ssm get-parameter \
    --name /monitoring/nrt-private-ip \
    --query "Parameter.Value" \
    --output text \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" 2>/dev/null) \
    || { echo "SSM_FETCH_FAILED:/monitoring/nrt-private-ip" >&2; exit 1; }

# Defensive shape check — VPC IPv4 only. Reject obvious garbage so a
# Prometheus startup failure isn't masked as "scrape target absent".
if ! [[ "${NRT_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: SSM returned non-IPv4 value '${NRT_IP}' for /monitoring/nrt-private-ip" >&2
    exit 1
fi

# Use jq so quoting is correct regardless of any future label additions.
jq -nc --arg ip "${NRT_IP}" '
  [
    {
      targets: [($ip + ":9100")],
      labels: {
        host: "nrt-router"
      }
    }
  ]
' > "${OUTPUT_FILE}"

chmod 644 "${OUTPUT_FILE}"
