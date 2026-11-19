#!/bin/bash
# Hermetic scenarios for cookbooks/lxc-es-memory/files/generate-proxy-allowed-subs.sh.
# Runs the PRODUCTION script unmodified with `aws` replaced by a stand-in on PATH
# that prints a fixture exactly as `aws ssm get-parameter --output text` would
# (the value, then a newline), records its arguments, and FAILS unless the call names
# the profile and region explicitly. No network, no AWS.
#
# What this protects: the script's output is a systemd EnvironmentFile for the memory
# proxy, and a file line overrides every Environment= of the unit. A value that is not
# a plain email list must NEVER be written, because a newline or a quote in it could
# override another variable of the proxy. The operator (the floor) must always stay in
# the list, and an address removed from the parameter must really drop out.
#
# Positive controls: against a mutant whose validation is removed, the injection
# scenario MUST write the injected line; against a mutant whose --check always
# succeeds, the two-line file MUST pass --check. If either does not, this harness
# cannot tell a working check from a missing one, and the run FAILS.
#
# Exit 0 when every assertion passes. One PASS/FAIL line per assertion.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../files/generate-proxy-allowed-subs.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/gpas-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $*"; }
bad() { fail=$((fail+1)); echo "FAIL  $*"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
assert_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 ('$2' not in $(basename "$3"))"; fi; }
assert_absent()   { if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1 ('$2' found in $(basename "$3"))"; else ok "$1"; fi; }

# aws stand-in: records its arguments, fails unless profile and region are named, then
# prints the fixture value + newline (or exits with the fixture code).
cat > "$T/bin/aws" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$GPAS_FAKE_ARGS"
[[ " $* " == *" --profile "* && " $* " == *" --region "* ]] || { echo "aws stand-in: --profile/--region missing" >&2; exit 252; }
[[ -f "$GPAS_FAKE_EXIT" ]] && exit "$(cat "$GPAS_FAKE_EXIT")"
cat "$GPAS_FAKE_VALUE"; echo
EOF
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH"
export GPAS_FAKE_VALUE="$T/value" GPAS_FAKE_EXIT="$T/exit" GPAS_FAKE_ARGS="$T/aws.args"
export AWS_PROFILE=test-profile AWS_REGION=test-region

OUT="$T/work/proxy-allowed-subs.env"
FLOOR='op@example.com'
SENTINEL='ALLOWED_SUBS=previous@example.com'

reset() { rm -f "$OUT" "$T/exit" "$T/stdout" "$T/stderr" "$GPAS_FAKE_ARGS"; printf '%s' "$1" > "$T/value"; }
seed_previous() { printf '%s\n' "$SENTINEL" > "$OUT"; }
run() { bash "$SCRIPT" "$OUT" "${1-$FLOOR}" > "$T/stdout" 2> "$T/stderr"; echo $?; }
tmp_leftovers() { find "$T/work" -name 'proxy-allowed-subs.env.*' | wc -l | tr -d ' '; }

echo "== S1 valid list is the union of the floor and the parameter"
reset 'alice@example.com,bob@example.org'
assert_eq "S1 exit 0" 0 "$(run)"
assert_eq "S1 content" 'ALLOWED_SUBS=op@example.com,alice@example.com,bob@example.org' "$(cat "$OUT")"
assert_eq "S1 exactly one line" 1 "$(wc -l < "$OUT" | tr -d ' ')"
mode=$(stat -c %a "$OUT" 2>/dev/null || stat -f %Lp "$OUT")
assert_eq "S1 mode 600" 600 "$mode"
assert_absent "S1 no address on stdout" '@' "$T/stdout"
assert_absent "S1 no address on stderr" '@' "$T/stderr"
assert_eq "S1 no temp file left" 0 "$(tmp_leftovers)"
assert_eq "S1 passes its own --check" 0 "$(bash "$SCRIPT" --check "$OUT" >/dev/null 2>&1; echo $?)"

echo "== S2 aws is called with the identity and parameter named explicitly"
assert_contains "S2 profile"          '--profile test-profile' "$GPAS_FAKE_ARGS"
assert_contains "S2 region"           '--region test-region' "$GPAS_FAKE_ARGS"
assert_contains "S2 dedicated param"  '--name /memory/proxy-allowed-subs' "$GPAS_FAKE_ARGS"
assert_contains "S2 decrypts"         '--with-decryption' "$GPAS_FAKE_ARGS"
assert_absent   "S2 never the consent list" '/hydra/' "$GPAS_FAKE_ARGS"

echo "== S3 a parameter without the operator cannot lock the operator out"
reset 'alice@example.com'
run >/dev/null
assert_contains "S3 operator still present" 'op@example.com' "$OUT"

echo "== S4 revocation: an address removed from the parameter drops out"
reset 'alice@example.com,bob@example.org'; run >/dev/null
reset 'alice@example.com'; run >/dev/null
assert_eq "S4 content" 'ALLOWED_SUBS=op@example.com,alice@example.com' "$(cat "$OUT")"
assert_absent "S4 removed address gone" 'bob@example.org' "$OUT"

echo "== S5 empty elements and duplicates are normalized"
reset 'op@example.com,,alice@example.com,alice@example.com,'
run >/dev/null
assert_eq "S5 content" 'ALLOWED_SUBS=op@example.com,alice@example.com' "$(cat "$OUT")"

echo "== S6 newline injection is rejected and the previous file is kept"
reset $'alice@example.com\nOIDC_JWKS_URL=http://evil.example/jwks'
seed_previous
assert_eq "S6 exit 0" 0 "$(run)"
assert_eq "S6 previous file untouched" "$SENTINEL" "$(cat "$OUT")"
assert_absent "S6 injected variable not written" 'OIDC_JWKS_URL' "$OUT"
assert_contains "S6 warns" 'WARN' "$T/stderr"
assert_eq "S6 no temp file left" 0 "$(tmp_leftovers)"
reset $'alice@example.com\nMEMORY_AUDIENCES='; seed_previous; run >/dev/null
assert_eq "S6 empty-audience injection rejected" "$SENTINEL" "$(cat "$OUT")"
reset $'alice@example.com\rX=1'; seed_previous; run >/dev/null
assert_eq "S6 carriage return rejected" "$SENTINEL" "$(cat "$OUT")"

echo "== S7 anything that is not a plain email list is rejected"
i=0
for v in 'a@b.co, c@d.co' '"a@b.co"' "'a@b.co'" 'a@b.co;x' '$(id)@b.co' 'a@b.co\' 'a%h@b.co' 'a=b@b.co' 'alice' '@b.co' 'a@b' 'a@b..co' $'a@b.co\tc@d.co' 'ａ@b.co' '#a@b.co' 'a@b.co#x' 'a@b.co,*' 'a@b.co,`id`'; do
  i=$((i+1)); reset "$v"; seed_previous; run >/dev/null
  assert_eq "S7.$i rejected: $(printf '%s' "$v" | head -c 30 | tr -c '[:print:]' '?')" "$SENTINEL" "$(cat "$OUT")"
done

echo "== S8 empty, blank and null values"
for v in '' ' ' 'None'; do
  reset "$v"; seed_previous; run >/dev/null
  assert_eq "S8 rejected: '$v'" "$SENTINEL" "$(cat "$OUT")"
done

echo "== S9 aws failure writes nothing and keeps the previous file"
reset 'alice@example.com'; echo 254 > "$T/exit"; seed_previous
assert_eq "S9 exit 0 (the caller keeps the old file)" 0 "$(run)"
assert_eq "S9 previous file untouched" "$SENTINEL" "$(cat "$OUT")"
rm -f "$T/exit"

echo "== S10 limits"
reset "$(printf 'a%.0s' $(seq 1 2100))@example.com"; seed_previous; run >/dev/null
assert_eq "S10 too long rejected" "$SENTINEL" "$(cat "$OUT")"
many=$(for n in $(seq 1 65); do printf 'u%d@example.com,' "$n"; done)
reset "$many"; seed_previous; run >/dev/null
assert_eq "S10 too many entries rejected" "$SENTINEL" "$(cat "$OUT")"

echo "== S11 the floor must be trustworthy: otherwise nothing is written"
reset 'alice@example.com'
for f in '' ' ' 'op@example.com,$(x)' 'not-an-email'; do
  seed_previous; run "$f" >/dev/null
  assert_eq "S11 floor '$f' -> nothing written" "$SENTINEL" "$(cat "$OUT")"
done
seed_previous; bash "$SCRIPT" "$OUT" > /dev/null 2>&1
assert_eq "S11 floor argument missing -> nothing written" "$SENTINEL" "$(cat "$OUT")"

echo "== S12 the identity is never taken from the ambient default"
reset 'alice@example.com'; seed_previous
( unset AWS_PROFILE; bash "$SCRIPT" "$OUT" "$FLOOR" > /dev/null 2>&1 )
assert_eq "S12 no AWS_PROFILE -> nothing written" "$SENTINEL" "$(cat "$OUT")"
if [[ -e $GPAS_FAKE_ARGS ]]; then bad "S12 aws was called without a profile"; else ok "S12 aws not called without a profile"; fi
seed_previous
( unset AWS_REGION; bash "$SCRIPT" "$OUT" "$FLOOR" > /dev/null 2>&1 )
assert_eq "S12 no AWS_REGION -> nothing written" "$SENTINEL" "$(cat "$OUT")"

echo "== S13 idempotent"
reset 'alice@example.com'; run >/dev/null; cp "$OUT" "$T/first"; run >/dev/null
if cmp -s "$T/first" "$OUT"; then ok "S13 identical on the second run"; else bad "S13 output changed between runs"; fi

echo "== S14 --check accepts only what the generator would write"
chk() { bash "$SCRIPT" --check "$1" >/dev/null 2>&1; echo $?; }
good="$T/chk-good"; printf 'ALLOWED_SUBS=op@example.com,alice@example.com\n' > "$good"
assert_eq "S14 valid file" 0 "$(chk "$good")"
n=0
while IFS= read -r -d '' body; do
  n=$((n+1)); f="$T/chk-bad-$n"; printf '%s' "$body" > "$f"
  assert_eq "S14.$n rejected: $(printf '%s' "$body" | head -c 36 | tr -c '[:print:]' '?')" 1 "$(chk "$f")"
done < <(printf '%s\0' \
  $'ALLOWED_SUBS=op@example.com\nOIDC_JWKS_URL=http://evil.example\n' \
  $'ALLOWED_SUBS=op@example.com\n\n' \
  $'ALLOWED_SUBS=op@example.com' \
  $'MEMORY_AUDIENCES=\n' \
  $'ALLOWED_SUBS="op@example.com"\n' \
  $'ALLOWED_SUBS=op@example.com,\n' \
  $'ALLOWED_SUBS=op@example.com\\\n' \
  $' ALLOWED_SUBS=op@example.com\n' \
  $'ALLOWED_SUBS=\n' \
  $'ALLOWED_SUBS=op@example.com x\n' \
  '')
assert_eq "S14 missing file" 1 "$(chk "$T/does-not-exist")"

echo "== C1 positive control: with the validation removed, the injection IS written"
MUT="$T/mutant-validation.sh"
sed 's/^normalize() {$/normalize() { printf "%s" "$1"; return 0/' "$SCRIPT" > "$MUT"
if cmp -s "$MUT" "$SCRIPT"; then
  bad "C1 the mutant is identical to the script (the sed no longer matches normalize())"
else
  reset $'alice@example.com\nOIDC_JWKS_URL=http://evil.example/jwks'
  bash "$MUT" "$OUT" "$FLOOR" > /dev/null 2>&1
  if grep -qF 'OIDC_JWKS_URL' "$OUT" 2>/dev/null; then ok "C1 the injection scenario detects a missing validation"; else bad "C1 the injection scenario cannot detect a missing validation"; fi
fi

echo "== C2 positive control: with --check always succeeding, a two-line file passes it"
MUT2="$T/mutant-check.sh"
sed 's/^if \[\[ \${1:-} == --check \]\]; then$/if [[ ${1:-} == --check ]]; then exit 0/' "$SCRIPT" > "$MUT2"
if cmp -s "$MUT2" "$SCRIPT"; then
  bad "C2 the mutant is identical to the script (the sed no longer matches the --check branch)"
else
  printf 'ALLOWED_SUBS=op@example.com\nOIDC_JWKS_URL=http://evil.example\n' > "$T/two-lines"
  if bash "$MUT2" --check "$T/two-lines" >/dev/null 2>&1; then ok "C2 the --check scenarios detect an always-true check"; else bad "C2 the --check scenarios cannot detect an always-true check"; fi
fi

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
