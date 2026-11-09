#!/bin/bash
# Source after session-search-era.sh. Never execute before digest/provenance.
ss_artifact() { # pin target destination; ss_manifest has populated ss_sums
  local pin=$1 target=$2 out=$3 want got
  [ "$ss_manifest_pin" = "$pin" ] || { ss_fail 'Rust artifact manifest pin mismatch'; return 1; }
  want=$(printf '%s\n' "$ss_sums" | awk -v target="$target" '$2 == target {print $1}')
  ss_hex "$want" 64 || { ss_fail "missing sha256 for $target"; return 1; }
  curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 120 \
    "https://github.com/shin1ohno/session-search/releases/download/ccs-$pin/ccs-$target" -o "$out" || { ss_fail 'artifact fetch'; return 1; }
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$out"); else got=$(shasum -a 256 "$out"); fi
  [ "${got%% *}" = "$want" ] || { ss_fail 'artifact sha256 mismatch'; return 1; }
  gh attestation verify --help | grep -q -- '--source-digest' || { ss_fail 'upgrade gh: attestation --source-digest is required'; return 1; }
  gh attestation verify "$out" --repo shin1ohno/session-search \
    --signer-workflow shin1ohno/session-search/.github/workflows/release.yml \
    --signer-digest "$pin" --source-digest "$pin" --source-ref refs/heads/main \
    --deny-self-hosted-runners > "$out.attestation" || { ss_fail 'artifact provenance mismatch'; return 1; }
  chmod 755 "$out" || return 1
  echo "PASS artifact digest and provenance $target $pin"
}
