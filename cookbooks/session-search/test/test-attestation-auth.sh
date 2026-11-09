#!/bin/bash
# Verify read-only job authentication against an existing public provenance.
# This archive is never extracted or executed. No Release is created.
set -euo pipefail
work=$(mktemp -d "${TMPDIR:-/tmp}/ccs-attestation.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/no-auth" "$work/job-auth"
asset=gh_2.103.3_windows_arm64.zip
digest=197211c98687d7770ac331fe8a3b6c198c389108c1536cdbedf659fe4703e484
commit=63837fb778d6a39f02be0ce76ff89f2bc8d74bdc
curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 120 \
  "https://github.com/cli/cli/releases/download/v2.103.3/$asset" -o "$work/$asset"
test "$(shasum -a 256 "$work/$asset" | cut -d' ' -f1)" = "$digest"
args=(attestation verify "$work/$asset" --repo cli/cli
  --signer-workflow cli/cli/.github/workflows/deployment.yml
  --signer-digest "$commit" --source-digest "$commit" --source-ref refs/heads/trunk
  --deny-self-hosted-runners --predicate-type https://slsa.dev/provenance/v1 --format json)
if env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$work/no-auth" gh "${args[@]}" > "$work/no-auth.log" 2>&1; then
  echo 'FAIL: unauthenticated gh unexpectedly succeeded'; exit 1
fi
grep -E 'gh auth login|GH_TOKEN' "$work/no-auth.log"
echo 'PASS no token and empty config rejected for authentication'
GH_CONFIG_DIR="$work/job-auth" gh "${args[@]}" > "$work/verified.json"
python3 - "$work/verified.json" "$digest" <<'PY'
import json, pathlib, sys
results = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert results, 'empty verification result'
assert sys.argv[2] in json.dumps(results), 'verified result does not name the artifact digest'
print('PASS read-only job token verified public artifact provenance and digest')
PY
