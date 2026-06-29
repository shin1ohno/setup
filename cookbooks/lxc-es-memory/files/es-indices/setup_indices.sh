#!/bin/bash
# Idempotently create the `knowledge` and `memory-user` ES indices.
# Usage: ES_URL=https://192.168.1.77:9200 ES_USER=elastic ES_PASSWORD=... \
#        setup_indices.sh [indices_dir]
#
# Safe to re-run: PUT /<index> returns 400 resource_already_exists_exception
# when the index is present, which this script treats as success.

set -euo pipefail

ES_URL="${ES_URL:?ES_URL required (e.g. https://192.168.1.77:9200)}"
ES_USER="${ES_USER:-elastic}"
ES_PASSWORD="${ES_PASSWORD:?ES_PASSWORD required}"
DIR="${1:-$(dirname "$0")}"

create_index() {
  local name="$1" body_file="$2"
  local code
  code=$(curl -sk -o /tmp/es-setup-resp.json -w '%{http_code}' \
    -u "${ES_USER}:${ES_PASSWORD}" \
    -X PUT "${ES_URL}/${name}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${body_file}")
  case "${code}" in
    200|201)
      echo "created index ${name}"
      ;;
    400)
      if grep -q 'resource_already_exists_exception' /tmp/es-setup-resp.json; then
        echo "index ${name} already exists — ok"
      else
        echo "ERROR creating ${name}: $(cat /tmp/es-setup-resp.json)" >&2
        return 1
      fi
      ;;
    *)
      echo "ERROR creating ${name} (HTTP ${code}): $(cat /tmp/es-setup-resp.json)" >&2
      return 1
      ;;
  esac
}

create_index "knowledge"   "${DIR}/knowledge.json"
create_index "memory-user" "${DIR}/memory-user.json"
echo "ES index setup complete."
