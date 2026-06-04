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

# Stage ES_HOSTS_YAML and ES_PASSWORD to temp files rather than passing
# them via `awk -v`. Two reasons:
#
#   1. macOS BWK awk forbids literal newlines in -v values ("awk: newline
#      in string"); gawk on Linux tolerates them. ES_HOSTS_YAML is
#      multi-line, so file-based read is mandatory for cross-platform.
#
#   2. awk's -v flag performs string-literal escape processing on the
#      value: `\&` in the bash value is consumed by -v to `&`, which
#      awk's gsub replacement then treats as "the matched text"
#      (re-emitting `@@ES_PASSWORD@@` into the rendered yml). Passing
#      the password via file + `getline` bypasses -v processing
#      entirely; only the gsub-replacement escape level remains.
#
# Per-level escapes for the password:
#   - `\` must become `\\` (awk gsub replacement: `\` is the escape char)
#   - `&` must become `\&` (awk gsub replacement: `&` = matched text)
#
HOSTS_FILE="$(mktemp)"
PASSWORD_FILE="$(mktemp)"
trap 'rm -f "${TMP_OUTPUT}" "${HOSTS_FILE}" "${PASSWORD_FILE}"' EXIT
chmod 0600 "${PASSWORD_FILE}"
printf '%s\n' "${ES_HOSTS_YAML}" > "${HOSTS_FILE}"
printf '%s' "${ES_PASSWORD}" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' > "${PASSWORD_FILE}"

awk \
    -v username="${ES_USERNAME}" \
    -v variant="${VARIANT}" \
    -v hostname="${HOSTNAME_SHORT}" \
    -v hosts_file="${HOSTS_FILE}" \
    -v password_file="${PASSWORD_FILE}" \
    '
    BEGIN {
        # Read pre-escaped password once. getline does not run the
        # awk string-literal escape pass that -v does, so the gsub
        # replacement sees the bytes exactly as written to the file.
        if ((getline password < password_file) <= 0) {
            print "generate_config.sh: failed to read password file" > "/dev/stderr"
            exit 1
        }
        close(password_file)
    }
    # Skip comment lines so @@MARKER@@ documentation in the template
    # header is not mistaken for a substitution site. Without this,
    # the comment `#   @@ES_HOSTS_YAML@@    multi-line YAML array of
    # ES URLs` triggers the host-list expansion at top level of the
    # rendered yml, which fails parsing with
    # `cannot unmarshal !!seq into map[string]interface {}`.
    /^[[:space:]]*#/ { print; next }
    {
        gsub(/@@ES_USERNAME@@/, username)
        gsub(/@@ES_PASSWORD@@/, password)
        gsub(/@@VARIANT@@/, variant)
        gsub(/@@HOSTNAME@@/, hostname)
        if ($0 ~ /@@ES_HOSTS_YAML@@/) {
            while ((getline line < hosts_file) > 0) print line
            close(hosts_file)
        } else {
            print
        }
    }
    ' "${TEMPLATE}" > "${TMP_OUTPUT}"

chmod 0600 "${TMP_OUTPUT}"
mv "${TMP_OUTPUT}" "${OUTPUT}"
trap - EXIT
