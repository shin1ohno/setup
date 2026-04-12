#!/bin/bash
# Mount ingest-drop S3 bucket via rclone
# Usage: mount.sh <rclone_conf> <mount_point>

set -euo pipefail

RCLONE_CONF="$1"
MOUNT_POINT="$2"

# Resolve symlinks to get the real mount target
if [[ -L "$MOUNT_POINT" ]]; then
  MOUNT_POINT="$(readlink -f "$MOUNT_POINT")"
fi

mkdir -p "$MOUNT_POINT"

exec rclone mount ingest-drop: "$MOUNT_POINT" \
  --config "$RCLONE_CONF" \
  --vfs-cache-mode writes \
  --allow-non-empty \
  --allow-other \
  --log-level INFO
