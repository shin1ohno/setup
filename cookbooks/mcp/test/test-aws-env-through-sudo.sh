#!/usr/bin/env bash
# Regression suite: the AWS identity the mcp auth gate checked is the one the
# SSM-fetching steps use.
#
# mitamae runs an `execute` that sets `user` as `sudo -H -u <user> -- /bin/sh -c`,
# and sudo's env_reset drops AWS_PROFILE. The gate (`require_external_auth`)
# checks in mitamae's own environment, so an operator on a named profile passed
# the gate and the generator then failed with "Unable to locate credentials".
#
# darwin.rb is rendered through a stub DSL (render-darwin.rb) with:
#   - a `sudo` stand-in that applies env_reset (keeps HOME and PATH only),
#   - an `aws` stand-in that records the identity variables it sees and fails
#     with "Unable to locate credentials" when the identity is not the one the
#     scenario requires (no AWS call is made),
#   - `yq` and `claude` stand-ins.
# Production generate_config.sh, register_claude_code.sh and
# as_user_aws_env.sh run unmodified.
#
# Negative run: the same scenarios against the pre-fix recipes
# (fixtures/pre-fix-*.rb.txt, verbatim from origin/main b6b2074) must FAIL on
# the cases the fix covers; that is the positive control for the harness.
#
# Override RECIPE_DIR to point the suite at another copy of cookbooks/mcp.
# TOOLS_PATH is prepended to PATH inside the fixtures: the scenarios run with a
# fixture HOME, which makes version-manager shims (mise, rbenv) misresolve ruby
# and jq, so a host that has only shims passes the real binary directories here.
# KEEP_WORK=1 keeps the work directory (it is under $TMPDIR).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
RECIPE_DIR=${RECIPE_DIR:-$(cd "$here/.." && pwd)}
RENDER=$here/render-darwin.rb

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

work=$(mktemp -d "${TMPDIR:-/tmp}/mcp-aws.XXXXXX")
if [ -z "${KEEP_WORK:-}" ]; then trap 'rm -rf "$work"' EXIT; fi

# --- stand-ins ---------------------------------------------------------------

stubs=$work/stubs
mkdir -p "$stubs"
export CALLS=$work/calls.log
: > "$CALLS"

# sudo's env_reset: only HOME and PATH survive; anything else must be passed as
# an explicit `env VAR=value` in front of the command.
cat > "$stubs/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -H ] || { echo "sudo stub: expected -H, got: $*" >&2; exit 1; }
[ "$2" = -u ] || { echo "sudo stub: expected -u, got: $*" >&2; exit 1; }
user=$3
[ "$4" = -- ] || { echo "sudo stub: expected --, got: $*" >&2; exit 1; }
shift 4
echo "sudo user=$user" >> "$CALLS"
exec env -i HOME="$HOME" PATH="$PATH" CALLS="$CALLS" "$@"
EOF

# aws: records the identity variables (never their secret values) and fails the
# way the real CLI does when the identity is not the required one.
cat > "$stubs/aws" <<'EOF'
#!/bin/sh
static=no
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && static=yes
printf 'aws profile=%s region=%s config=%s credfile=%s static=%s argv=%s\n' \
  "${AWS_PROFILE-<unset>}" "${AWS_REGION-<unset>}" "${AWS_CONFIG_FILE-<unset>}" \
  "${AWS_SHARED_CREDENTIALS_FILE-<unset>}" "$static" "$*" >> "$CALLS"
nocred() {
  echo "aws: [ERROR]: An error occurred (NoCredentials): Unable to locate credentials" >&2
  exit 255
}
# The scenario's policy lives in a file beside the stub: sudo's env_reset would
# drop an environment variable carrying it, which is the very effect under test.
policy=$(dirname "$0")/aws.policy
IFS= read -r mode < "$policy"
value=$(sed -n 2p "$policy")
case "$*" in
  *"sts get-caller-identity"*) echo '{"Arn": "arn:aws:iam::000000000000:user/fixture"}'; exit 0 ;;
esac
case "$mode" in
  not-found)
    echo "An error occurred (ParameterNotFound) when calling the GetParameter operation:" >&2
    exit 254 ;;
  require-profile) [ "${AWS_PROFILE-}" = "$value" ] || nocred ;;
  accept-env-key)  [ -n "${AWS_ACCESS_KEY_ID:-}" ] || nocred ;;
esac
case "$*" in
  *Parameter.Name*) echo /mcp/obsidian-api-key ;;
  *) echo FAKE-SSM-VALUE-9f3a ;;
esac
EOF

# yq: the YAML -> JSON conversion the generators ask for.
cat > "$stubs/yq" <<'EOF'
#!/bin/sh
[ "$1" = --help ] && { echo "yq (mikefarah stand-in)"; exit 0; }
for last; do :; done
exec ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV.last), aliases: true))' "$last"
EOF

cat > "$stubs/claude" <<'EOF'
#!/bin/sh
# Records the subcommand only: the add-json argument carries the SSM value.
echo "claude $1 $2" >> "$CALLS"
[ "$1 $2" = "mcp list" ] && exit 0
exit 0
EOF
chmod +x "$stubs"/*

# --- scenario runner -----------------------------------------------------------

# run_scenario NAME RECIPE_DIR [VAR=value ...]  -> sets $out, $rc, $calls_of_run.
# A fresh fixture home per scenario; the setup root inside it holds a space on
# purpose (generated_dir / temp_path are interpolated into a command line).
run_scenario() {
  local name=$1 recipes=$2 arg
  shift 2
  local env_args=()
  printf 'any\n' > "$stubs/aws.policy"
  for arg in "$@"; do
    case "$arg" in
      FAKE_AWS_REQUIRE_PROFILE=*) printf 'require-profile\n%s\n' "${arg#*=}" > "$stubs/aws.policy" ;;
      FAKE_AWS_PARAMETER_NOT_FOUND=*) printf 'not-found\n' > "$stubs/aws.policy" ;;
      FAKE_AWS_ACCEPT_ENV_KEY=*) printf 'accept-env-key\n' > "$stubs/aws.policy" ;;
      *) env_args+=("$arg") ;;
    esac
  done
  home="$work/$name/fixture-home"
  mkdir -p "$home/.local/bin" "$home/.local/share/mise/shims"
  : > "$home/.fixture-home"
  cp "$stubs/claude" "$home/.local/bin/claude"
  # register.rb puts $HOME/.local/share/mise/shims and /usr/local/bin in front
  # of PATH; a real awscli in /usr/local/bin would win over the stand-in. The
  # stand-ins are therefore also the first entries of that shims directory, so
  # no scenario can reach a real aws.
  cp "$stubs/aws" "$stubs/yq" "$home/.local/share/mise/shims/"
  ln -sf "$stubs/aws.policy" "$home/.local/share/mise/shims/aws.policy"
  : > "$CALLS"
  out=$(env -i HOME="$home" PATH="$stubs:${TOOLS_PATH:+$TOOLS_PATH:}$PATH" CALLS="$CALLS" TMPDIR="${TMPDIR:-/tmp}" \
        MARK_DIR="$work/$name" ${env_args[@]+"${env_args[@]}"} ruby "$RENDER" "$recipes" "$home" 2>&1)
  rc=$?
  calls_of_run=$(cat "$CALLS")
  echo "$out" > "$work/$name.out"
  cp "$CALLS" "$work/$name.calls"
  printf '%s\n' "$home" > "$work/$name.home"
}

aws_calls() { printf '%s\n' "$calls_of_run" | grep -c '^aws '; }
aws_lines_with() { printf '%s\n' "$calls_of_run" | grep '^aws ' | grep -cF -- "$1"; }
config_of() { printf '%s/Library/Application Support/Claude/claude_desktop_config.json' "$(cat "$work/$1.home")"; }

# Legacy recipe copy: the production files/ directory plus the pre-fix recipes.
legacy=$work/legacy
mkdir -p "$legacy"
cp "$here/fixtures/pre-fix-darwin.rb.txt" "$legacy/darwin.rb"
cp "$here/fixtures/pre-fix-register.rb.txt" "$legacy/register.rb"
ln -s "$RECIPE_DIR/files" "$legacy/files"

PROFILE=fixture-profile

# --- 0. harness guard: no scenario can reach a real aws ---------------------------

guard_home=$work/guard-home
mkdir -p "$guard_home/.local/share/mise/shims"
cp "$stubs/aws" "$guard_home/.local/share/mise/shims/"
resolved=$(env -i HOME="$guard_home" PATH="$stubs:$PATH" \
  sh -c 'PATH="$HOME/.local/share/mise/shims:/usr/local/bin:$PATH"; command -v aws')
check "harness: register's PATH (shims, /usr/local/bin, ...) still resolves aws to the stand-in" \
  '[ "$resolved" = "$guard_home/.local/share/mise/shims/aws" ]'

# --- 1. named profile (the owner's failure) ------------------------------------

run_scenario named-profile "$RECIPE_DIR" AWS_PROFILE=$PROFILE FAKE_AWS_REQUIRE_PROFILE=$PROFILE
check "named profile: apply succeeds" '[ "$rc" = 0 ]'
check "named profile: gate, generator and register = 3 aws calls" '[ "$(aws_calls)" = 3 ]'
check "named profile: every aws call sees AWS_PROFILE=$PROFILE" '[ "$(aws_lines_with "profile=$PROFILE ")" = 3 ]'
check "named profile: managed config written with the obsidian server" 'grep -q "\"obsidian-mcp-tools\"" "$(config_of named-profile)"'
check "named profile: config file is 0600" '[ "$(stat -c %a "$(config_of named-profile)" 2>/dev/null || stat -f %Lp "$(config_of named-profile)")" = 600 ]'
check "named profile: register ran (claude mcp add-json)" 'printf "%s\n" "$calls_of_run" | grep -q "^claude mcp add-json"'
check "named profile: no execute carries its own user (nothing goes through mitamae sudo wrap)" '! printf "%s\n" "$out" | grep -q "via=sudo"'
check "named profile: gate check does not pin a profile (keeps auto-discovery)" '! printf "%s\n" "$out" | grep "^GATE check:" | grep -Eq "AWS_PROFILE=|--profile"'
check "named profile: gate prints no decrypted value (--query Parameter.Name)" 'printf "%s\n" "$out" | grep "^GATE check:" | grep -q "Parameter.Name"'

# --- 2. negative run: pre-fix recipes ------------------------------------------

run_scenario named-profile-legacy "$legacy" AWS_PROFILE=$PROFILE FAKE_AWS_REQUIRE_PROFILE=$PROFILE
check "pre-fix recipes: apply aborts on the named profile (positive control)" '[ "$rc" != 0 ]'
check "pre-fix recipes: gate saw the profile" '[ "$(printf "%s\n" "$calls_of_run" | grep "^aws " | head -1 | grep -cF "profile=$PROFILE ")" = 1 ]'
check "pre-fix recipes: generator lost it (profile=<unset>)" 'printf "%s\n" "$calls_of_run" | grep "^aws " | tail -1 | grep -qF "profile=<unset> "'
check "pre-fix recipes: failure text is NoCredentials" 'grep -q "NoCredentials" "$work/named-profile-legacy.out" && grep -q "SSM fetch failed for /mcp/obsidian-api-key" "$work/named-profile-legacy.out"'

# --- 3. every forwarded variable ----------------------------------------------

run_scenario all-four "$RECIPE_DIR" AWS_PROFILE=$PROFILE FAKE_AWS_REQUIRE_PROFILE=$PROFILE \
  AWS_REGION=us-west-2 AWS_CONFIG_FILE="/fixture/cfg dir/config" AWS_SHARED_CREDENTIALS_FILE=/fixture/creds
check "all four variables: apply succeeds" '[ "$rc" = 0 ]'
check "all four variables: AWS_REGION reaches all 3 calls" '[ "$(aws_lines_with "region=us-west-2 ")" = 3 ]'
check "all four variables: AWS_CONFIG_FILE (with a space) reaches all 3 calls" '[ "$(aws_lines_with "config=/fixture/cfg dir/config ")" = 3 ]'
check "all four variables: AWS_SHARED_CREDENTIALS_FILE reaches all 3 calls" '[ "$(aws_lines_with "credfile=/fixture/creds ")" = 3 ]'

# --- 4. default-profile path unchanged ------------------------------------------

run_scenario default-profile "$RECIPE_DIR"
check "default profile: apply succeeds" '[ "$rc" = 0 ]'
check "default profile: no identity variable is invented (profile/region/config/credfile all unset)" \
  '[ "$(aws_lines_with "profile=<unset> region=<unset> config=<unset> credfile=<unset> static=no")" = 3 ]'

run_scenario empty-profile "$RECIPE_DIR" AWS_PROFILE=
check "empty AWS_PROFILE is not forwarded" '[ "$rc" = 0 ] && [ "$(aws_lines_with "profile=<unset> ")" = 3 ]'

# --- 5. hostile values are data -------------------------------------------------

evil="p'r \$(touch $work/PWNED) ;x"
run_scenario hostile-profile "$RECIPE_DIR" "AWS_PROFILE=$evil" "FAKE_AWS_REQUIRE_PROFILE=$evil"
check "hostile profile name: forwarded byte-for-byte to all 3 calls" '[ "$rc" = 0 ] && [ "$(aws_lines_with "profile=$evil region=")" = 3 ]'
check "hostile profile name: nothing was executed" '[ ! -e "$work/PWNED" ]'

# --- 6. environment-only static credentials --------------------------------------

keyid=AKIAFIXTUREKEYID0000
secret=FIXTURE-SECRET-ACCESS-KEY-0000
run_scenario static-env "$RECIPE_DIR" AWS_ACCESS_KEY_ID=$keyid AWS_SECRET_ACCESS_KEY=$secret FAKE_AWS_ACCEPT_ENV_KEY=1
check "static env keys: gate fails up front (exactly 1 aws call, the gate)" '[ "$(aws_calls)" = 1 ] && printf "%s\n" "$out" | grep -q "^GATE failed"'
check "static env keys: gated block skipped, no config written, apply does not abort" '[ "$rc" = 0 ] && [ ! -e "$(config_of static-env)" ]'

run_scenario static-env-legacy "$legacy" AWS_ACCESS_KEY_ID=$keyid AWS_SECRET_ACCESS_KEY=$secret FAKE_AWS_ACCEPT_ENV_KEY=1
check "pre-fix recipes: static env keys pass the gate and abort the generator (positive control)" '[ "$rc" != 0 ] && printf "%s\n" "$out" | grep -q "^GATE ok" && grep -q NoCredentials "$work/static-env-legacy.out"'

# --- 7. no identity at all -------------------------------------------------------

run_scenario no-identity "$RECIPE_DIR" FAKE_AWS_REQUIRE_PROFILE=$PROFILE
check "no usable identity: gate fails, nothing else runs" '[ "$rc" = 0 ] && [ "$(aws_calls)" = 1 ] && printf "%s\n" "$out" | grep -q "^GATE failed"'

# --- 8. credentials and values never reach logs ----------------------------------

all_text=$(cat "$work"/*.out "$work"/*.calls)
check "no static key id or secret in any output or call log" '! printf "%s" "$all_text" | grep -qE "$keyid|$secret"'
check "no decrypted SSM value in any output or call log" '! printf "%s" "$all_text" | grep -q "FAKE-SSM-VALUE"'

# --- 9. the wrapper on its own ----------------------------------------------------

wrapper=$RECIPE_DIR/files/as_user_aws_env.sh
wenv=$(env -i HOME="$work" PATH="$stubs:$PATH" CALLS="$CALLS" AWS_PROFILE=a AWS_REGION= AWS_ACCESS_KEY_ID=$keyid \
  bash "$wrapper" someone printenv 2>/dev/null | sort | tr '\n' ' ')
check "wrapper forwards a set variable" 'printf "%s" "$wenv" | grep -qF "AWS_PROFILE=a "'
check "wrapper drops an empty variable and static credentials" '! printf "%s" "$wenv" | grep -qE "AWS_REGION|AWS_ACCESS_KEY_ID"'
env -i HOME="$work" PATH="$stubs:$PATH" CALLS="$CALLS" bash "$wrapper" someone true >/dev/null 2>&1
check "wrapper runs with no variable set (empty array under set -u)" '[ $? = 0 ]'
env -i HOME="$work" PATH="$stubs:$PATH" bash "$wrapper" onlyuser >/dev/null 2>&1
check "wrapper without a command exits 64" '[ $? = 64 ]'
wlog=$(env -i HOME="$work" PATH="$stubs:$PATH" CALLS="$CALLS" AWS_PROFILE=secretish-name-0 AWS_REGION=secretish-region-0 bash "$wrapper" someone true 2>&1)
check "wrapper prints nothing of its own (no variable name or value)" '[ -z "$wlog" ]'

# --- 10. the TTY gate's Diagnosis shows the AWS error ------------------------------
# On the interactive path the gate prints `_auth_diagnosis` (production helper,
# evaluated by render-darwin.rb) whose last line of defence is the FIRST output
# line of the failing check. A log line of the wrapper would hide the AWS error.

run_scenario diagnosis "$RECIPE_DIR" AWS_PROFILE=$PROFILE FAKE_AWS_PARAMETER_NOT_FOUND=1 RENDER_DIAGNOSE=1
check "diagnosis: gate fails on ParameterNotFound and the block is skipped" '[ "$rc" = 0 ] && printf "%s\n" "$out" | grep -q "^GATE failed" && [ "$(aws_calls)" -ge 1 ]'
check "diagnosis: shows the AWS error (ParameterNotFound)" 'printf "%s\n" "$out" | grep "^GATE diagnosis:" | grep -q "the SSM parameter does not exist: An error occurred (ParameterNotFound)"'
check "diagnosis: does not show a wrapper log line" '! printf "%s\n" "$out" | grep "^GATE diagnosis:" | grep -q "as_user_aws_env"'

# Positive control: a wrapper that logs (the shape reviewed in PR 1252, head ae906bc)
# must make the diagnosis check above fail.
mutant=$work/mutant
mkdir -p "$mutant"
cp -R "$RECIPE_DIR/darwin.rb" "$RECIPE_DIR/register.rb" "$RECIPE_DIR/files" "$mutant/"
awk '{print} /^shift$/ && !done {print "echo \"as_user_aws_env: forwarding AWS_PROFILE to ${target_user}\" >&2"; done=1}' \
  "$RECIPE_DIR/files/as_user_aws_env.sh" > "$mutant/files/as_user_aws_env.sh"
run_scenario diagnosis-mutant "$mutant" AWS_PROFILE=$PROFILE FAKE_AWS_PARAMETER_NOT_FOUND=1 RENDER_DIAGNOSE=1
check "diagnosis: a wrapper that logs hides the AWS error (positive control)" 'printf "%s\n" "$out" | grep "^GATE diagnosis:" | grep -q "as_user_aws_env"'

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) FAILED"; fi
[ "$fails" -eq 0 ]
