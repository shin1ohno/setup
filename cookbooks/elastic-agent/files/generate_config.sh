#!/bin/bash
# Render elastic-agent.yml from the cookbook template by fetching the ES
# password from SSM and substituting it together with the variant +
# hostname. Output written to "$OUTPUT" (caller `sudo install`s it).
#
# Required env (passed by cookbooks/elastic-agent/default.rb):
#   AWS_PROFILE
#   AWS_REGION
#   ES_PASSWORD_SSM    SSM path to the elastic_agent_writer password
#   ES_USERNAME        ES username (e.g. elastic_agent_writer)
#   VARIANT            "air" | "neo"
#   TEMPLATE           absolute path to elastic-agent.yml.tmpl
#   OUTPUT             absolute path to write the rendered yml

set -euo pipefail

: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${ES_PASSWORD_SSM:?ES_PASSWORD_SSM is required}"
: "${ES_USERNAME:?ES_USERNAME is required}"
: "${VARIANT:?VARIANT is required}"
: "${TEMPLATE:?TEMPLATE is required}"
: "${OUTPUT:?OUTPUT is required}"

if [[ ! -f "${TEMPLATE}" ]]; then
    echo "generate_config.sh: TEMPLATE '${TEMPLATE}' not found" >&2
    exit 1
fi

ES_PASSWORD=$(
    aws ssm get-parameter \
        --name "${ES_PASSWORD_SSM}" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}"
)

if [[ -z "${ES_PASSWORD}" || "${ES_PASSWORD}" == "None" ]]; then
    echo "generate_config.sh: SSM fetch returned empty/None for ${ES_PASSWORD_SSM}" >&2
    exit 1
fi

# Multi-line ES_HOSTS_YAML default (matches cookbook default if env unset).
ES_HOSTS_YAML="${ES_HOSTS_YAML:-$(cat <<'YML'
    - http://es-0.home.local:9200
    - http://es-1.home.local:9200
    - http://es-2.home.local:9200
YML
)}"

HOSTNAME_SHORT=$(hostname -s)

# Use a temp file then atomic rename so partial writes never reach OUTPUT.
TMP_OUTPUT="${OUTPUT}.tmp.$$"
trap 'rm -f "${TMP_OUTPUT}"' EXIT

# awk-based substitution avoids sed's headaches with passwords containing
# `/`, `&`, or `\`. Each marker is a literal single-line substitution
# except @@ES_HOSTS_YAML@@ which expands to multiple indented lines.
awk \
    -v username="${ES_USERNAME}" \
    -v password="${ES_PASSWORD}" \
    -v variant="${VARIANT}" \
    -v hostname="${HOSTNAME_SHORT}" \
    -v hosts_yaml="${ES_HOSTS_YAML}" \
    '
    {
        gsub(/@@ES_USERNAME@@/, username)
        gsub(/@@ES_PASSWORD@@/, password)
        gsub(/@@VARIANT@@/, variant)
        gsub(/@@HOSTNAME@@/, hostname)
        if ($0 ~ /@@ES_HOSTS_YAML@@/) {
            print hosts_yaml
        } else {
            print
        }
    }
    ' "${TEMPLATE}" > "${TMP_OUTPUT}"

chmod 0600 "${TMP_OUTPUT}"
mv "${TMP_OUTPUT}" "${OUTPUT}"
trap - EXIT
