#!/usr/bin/env bash

# Black-box tests for the hr shell function.  Every case runs in a fresh shell,
# with isolated herdr/fzf executables and no access to the real binaries by PATH.

if [ "$#" -ne 1 ]; then
  printf 'Usage: bash %s <path-to-hr.sh>\n' "${0##*/}" >&2
  exit 2
fi

case $1 in
  /*) HR_FILE=$1 ;;
  *) HR_FILE=$PWD/$1 ;;
esac

if [ ! -r "$HR_FILE" ]; then
  printf 'test-hr: cannot read %s\n' "$HR_FILE" >&2
  exit 2
fi

BASH_BIN=$(command -v bash 2>/dev/null)
ZSH_BIN=$(command -v zsh 2>/dev/null)
ENV_BIN=$(command -v env 2>/dev/null)
if [ -z "$BASH_BIN" ] || [ -z "$ZSH_BIN" ] || [ -z "$ENV_BIN" ]; then
  printf 'test-hr: bash, zsh, and env are required\n' >&2
  exit 2
fi

ORIGINAL_PATH=$PATH
TMP_PARENT=${TMPDIR:-/tmp}
case $TMP_PARENT in
  /*) ;;
  *) TMP_PARENT=$PWD/$TMP_PARENT ;;
esac
TEST_ROOT=$(mktemp -d "$TMP_PARENT/test-hr.XXXXXX") || exit 2

cleanup() {
  cleanup_status=$?
  trap - EXIT
  if [ -n "${TEST_ROOT-}" ] && [ -d "$TEST_ROOT" ]; then
    rm -rf -- "$TEST_ROOT"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

STUB_BIN=$TEST_ROOT/stubs
NO_FZF_BIN=$TEST_ROOT/no-fzf
SAFE_BIN=$TEST_ROOT/safe-bin
RESULT_DIR=$TEST_ROOT/results
CASE_CWD=$TEST_ROOT/case-cwd
CHILD_TMP=$TEST_ROOT/child-tmp
mkdir -p "$STUB_BIN" "$NO_FZF_BIN" "$SAFE_BIN" "$RESULT_DIR" "$CASE_CWD" "$CHILD_TMP" || exit 2

# Preserve ordinary implementation choices (awk, sed, etc.) for the missing-fzf
# case while excluding both real programs from every test's PATH.
OLD_IFS=$IFS
IFS=:
for path_dir in $ORIGINAL_PATH; do
  [ -n "$path_dir" ] || path_dir=.
  for executable in "$path_dir"/*; do
    [ -x "$executable" ] && [ ! -d "$executable" ] || continue
    command_name=${executable##*/}
    case $command_name in
      herdr|fzf|hr) continue ;;
    esac
    if [ ! -e "$SAFE_BIN/$command_name" ] && [ ! -L "$SAFE_BIN/$command_name" ]; then
      ln -s "$executable" "$SAFE_BIN/$command_name" 2>/dev/null || :
    fi
  done
done
IFS=$OLD_IFS

cat >"$STUB_BIN/herdr" <<'STUB'
#!/bin/sh
{
  printf '%s' "$#"
  for argument in "$@"; do
    printf '\t%s' "$argument"
  done
  printf '\n'
} >>"${HR_TEST_HERDR_LOG:?}"

if [ "$#" -eq 2 ] && [ "$1" = session ] && [ "$2" = list ]; then
  printf '%s' "${HR_TEST_LIST_OUTPUT-}"
  [ -z "${HR_TEST_LIST_STDERR-}" ] || printf '%s' "$HR_TEST_LIST_STDERR" >&2
  exit "${HR_TEST_LIST_STATUS-0}"
fi
if [ "$#" -eq 3 ] && [ "$1" = session ] && [ "$2" = attach ]; then
  printf '%s' "${HR_TEST_ATTACH_OUTPUT-}"
  [ -z "${HR_TEST_ATTACH_STDERR-}" ] || printf '%s' "$HR_TEST_ATTACH_STDERR" >&2
  exit "${HR_TEST_ATTACH_STATUS-0}"
fi
if [ "$#" -eq 2 ] && [ "$1" = --session ]; then
  printf '%s' "${HR_TEST_NAMED_OUTPUT-}"
  [ -z "${HR_TEST_NAMED_STDERR-}" ] || printf '%s' "$HR_TEST_NAMED_STDERR" >&2
  exit "${HR_TEST_NAMED_STATUS-0}"
fi
if [ "$#" -eq 0 ]; then
  printf '%s' "${HR_TEST_BARE_OUTPUT-}"
  [ -z "${HR_TEST_BARE_STDERR-}" ] || printf '%s' "$HR_TEST_BARE_STDERR" >&2
  exit "${HR_TEST_BARE_STATUS-0}"
fi
printf 'herdr test stub: unexpected argv\n' >&2
exit 97
STUB

cat >"$STUB_BIN/fzf" <<'STUB'
#!/bin/sh
{
  printf '%s' "$#"
  for argument in "$@"; do
    printf '\t%s' "$argument"
  done
  printf '\n'
} >>"${HR_TEST_FZF_LOG:?}"
/bin/cat >"${HR_TEST_FZF_INPUT:?}"
printf '%s' "${HR_TEST_FZF_OUTPUT-}"
[ -z "${HR_TEST_FZF_STDERR-}" ] || printf '%s' "$HR_TEST_FZF_STDERR" >&2
exit "${HR_TEST_FZF_STATUS-0}"
STUB

chmod 755 "$STUB_BIN/herdr" "$STUB_BIN/fzf" || exit 2
ln -s "$STUB_BIN/herdr" "$NO_FZF_BIN/herdr" || exit 2

# Matching files expose an unquoted parameter as a changed argv under bash.
: >"$CASE_CWD/meta;_EXPANDED_session"
: >"$CASE_CWD/pick;_EXPANDED_session"

RUNNER=$TEST_ROOT/run-case.sh
cat >"$RUNNER" <<'RUNNER'
# This file is explicitly interpreted by bash or zsh; keep its syntax common.
__hr_test_state=$HR_TEST_STATE
: >"$__hr_test_state" || exit 124
cd "$HR_TEST_CASE_CWD" || exit 124

if [ "$HR_TEST_INSIDE" = 1 ]; then
  HERDR_ENV=1
  export HERDR_ENV
else
  unset HERDR_ENV
fi

__hr_test_herdr=$(command -v herdr 2>/dev/null)
if [ "$__hr_test_herdr" != "$HR_TEST_STUB_DIR/herdr" ]; then
  printf 'PREFLIGHT=herdr:%s\n' "$__hr_test_herdr" >>"$__hr_test_state"
  exit 125
fi

if [ "$HR_TEST_EXPECT_FZF" = present ]; then
  __hr_test_fzf=$(command -v fzf 2>/dev/null)
  if [ "$__hr_test_fzf" != "$HR_TEST_STUB_DIR/fzf" ]; then
    printf 'PREFLIGHT=fzf:%s\n' "$__hr_test_fzf" >>"$__hr_test_state"
    exit 125
  fi
else
  if __hr_test_fzf=$(command -v fzf 2>/dev/null); then
    printf 'PREFLIGHT=fzf-present:%s\n' "$__hr_test_fzf" >>"$__hr_test_state"
    exit 125
  fi
fi
printf 'PREFLIGHT=ok\n' >>"$__hr_test_state"

# Preset plausible helper names so a missing local declaration is observable.
session='sentinel:session'
sessions='sentinel:sessions'
selected_session='sentinel:selected_session'
selected='sentinel:selected'
selection='sentinel:selection'
choice='sentinel:choice'
candidate='sentinel:candidate'
candidates='sentinel:candidates'
list_output='sentinel:list_output'
fzf_status='sentinel:fzf_status'
session_list='sentinel:session_list'
list_status='sentinel:list_status'
picked='sentinel:picked'
pick='sentinel:pick'
names='sentinel:names'
name='sentinel:name'
output='sentinel:output'
result='sentinel:result'
rc='sentinel:rc'
command_status='sentinel:command_status'
fzf_output='sentinel:fzf_output'
fzf_result='sentinel:fzf_result'
hr_status='sentinel:hr_status'
ret='sentinel:ret'
return_code='sentinel:return_code'
value='sentinel:value'
list_result='sentinel:list_result'
session_name='sentinel:session_name'
selected_name='sentinel:selected_name'
fzf_rc='sentinel:fzf_rc'
list_rc='sentinel:list_rc'
attach_rc='sentinel:attach_rc'
__hr_test_original_ifs=$IFS

. "$HR_TEST_HR_PATH"
__hr_test_source_status=$?
if [ "$__hr_test_source_status" -ne 0 ] || ! typeset -f hr >/dev/null 2>&1; then
  printf 'SOURCE=%s\n' "$__hr_test_source_status" >>"$__hr_test_state"
  exit 126
fi

# A sourced file must not replace the isolated tools or rewrite PATH to reach a
# real installation before its function is exercised.
__hr_test_herdr=$(command -v herdr 2>/dev/null)
if [ "$__hr_test_herdr" != "$HR_TEST_STUB_DIR/herdr" ]; then
  printf 'PREFLIGHT=post-source-herdr:%s\n' "$__hr_test_herdr" >>"$__hr_test_state"
  exit 125
fi
if [ "$HR_TEST_EXPECT_FZF" = present ]; then
  __hr_test_fzf=$(command -v fzf 2>/dev/null)
  if [ "$__hr_test_fzf" != "$HR_TEST_STUB_DIR/fzf" ]; then
    printf 'PREFLIGHT=post-source-fzf:%s\n' "$__hr_test_fzf" >>"$__hr_test_state"
    exit 125
  fi
else
  if __hr_test_fzf=$(command -v fzf 2>/dev/null); then
    printf 'PREFLIGHT=post-source-fzf-present:%s\n' "$__hr_test_fzf" >>"$__hr_test_state"
    exit 125
  fi
fi

[ "$HR_TEST_SET_U" = 1 ] && set -u
[ "$HR_TEST_SET_E" = 1 ] && set -e

case $HR_TEST_MODE in
  source_only)
    __hr_test_rc=0
    ;;
  named)
    if hr "$HR_TEST_NAME"; then
      __hr_test_rc=0
    else
      __hr_test_rc=$?
    fi
    ;;
  bare)
    if hr; then
      __hr_test_rc=0
    else
      __hr_test_rc=$?
    fi
    ;;
  *)
    exit 127
    ;;
esac

__hr_test_options=$-
set +e
{
  printf 'RC=%s\n' "$__hr_test_rc"
  printf 'OPTIONS=%s\n' "$__hr_test_options"
  printf 'SESSION=%s\n' "${session-__UNSET__}"
  printf 'SESSIONS=%s\n' "${sessions-__UNSET__}"
  printf 'SELECTED_SESSION=%s\n' "${selected_session-__UNSET__}"
  printf 'SELECTED=%s\n' "${selected-__UNSET__}"
  printf 'SELECTION=%s\n' "${selection-__UNSET__}"
  printf 'CHOICE=%s\n' "${choice-__UNSET__}"
  printf 'CANDIDATE=%s\n' "${candidate-__UNSET__}"
  printf 'CANDIDATES=%s\n' "${candidates-__UNSET__}"
  printf 'LIST_OUTPUT=%s\n' "${list_output-__UNSET__}"
  printf 'FZF_STATUS=%s\n' "${fzf_status-__UNSET__}"
  printf 'SESSION_LIST=%s\n' "${session_list-__UNSET__}"
  printf 'LIST_STATUS=%s\n' "${list_status-__UNSET__}"
  printf 'PICKED=%s\n' "${picked-__UNSET__}"
  printf 'PICK=%s\n' "${pick-__UNSET__}"
  printf 'NAMES=%s\n' "${names-__UNSET__}"
  printf 'NAME=%s\n' "${name-__UNSET__}"
  printf 'OUTPUT=%s\n' "${output-__UNSET__}"
  printf 'RESULT=%s\n' "${result-__UNSET__}"
  printf 'RC_HELPER=%s\n' "${rc-__UNSET__}"
  printf 'COMMAND_STATUS=%s\n' "${command_status-__UNSET__}"
  printf 'FZF_OUTPUT=%s\n' "${fzf_output-__UNSET__}"
  printf 'FZF_RESULT=%s\n' "${fzf_result-__UNSET__}"
  printf 'HR_STATUS=%s\n' "${hr_status-__UNSET__}"
  printf 'RET=%s\n' "${ret-__UNSET__}"
  printf 'RETURN_CODE=%s\n' "${return_code-__UNSET__}"
  printf 'VALUE=%s\n' "${value-__UNSET__}"
  printf 'LIST_RESULT=%s\n' "${list_result-__UNSET__}"
  printf 'SESSION_NAME=%s\n' "${session_name-__UNSET__}"
  printf 'SELECTED_NAME=%s\n' "${selected_name-__UNSET__}"
  printf 'FZF_RC=%s\n' "${fzf_rc-__UNSET__}"
  printf 'LIST_RC=%s\n' "${list_rc-__UNSET__}"
  printf 'ATTACH_RC=%s\n' "${attach_rc-__UNSET__}"
  if [ "$IFS" = "$__hr_test_original_ifs" ]; then
    printf 'IFS_PRESERVED=1\n'
  else
    printf 'IFS_PRESERVED=0\n'
  fi
  printf 'DONE=1\n'
} >>"$__hr_test_state"
exit 0
RUNNER

declare -A STATE_CACHE
add_issue() {
  if [ -n "$SHELL_ISSUES" ]; then
    SHELL_ISSUES="$SHELL_ISSUES; $1"
  else
    SHELL_ISSUES=$1
  fi
}

file_summary() {
  if [ ! -s "$1" ]; then
    printf '<empty>'
  else
    tr '\t\n' ' |' <"$1" | cut -c1-180
  fi
}

check_rc() {
  if [ "$OBSERVED_RC" != "$1" ]; then
    add_issue "status was $OBSERVED_RC"
  fi
}

check_nonzero_rc() {
  case $OBSERVED_RC in
    ''|'<missing>'|*[!0-9]*) add_issue "status was $OBSERVED_RC" ;;
    0) add_issue 'status was 0' ;;
  esac
}

check_herdr_exact() {
  expected=$1
  EXPECTED_FILE=$RESULT_BASE.expected-herdr
  if [ -n "$expected" ]; then
    printf '%s\n' "$expected" >"$EXPECTED_FILE"
  else
    : >"$EXPECTED_FILE"
  fi
  if ! cmp -s "$EXPECTED_FILE" "$HERDR_LOG"; then
    add_issue "herdr argv log was $(file_summary "$HERDR_LOG")"
  fi
}

check_herdr_empty_or_list() {
  actual=$(sed -n '1,3p' "$HERDR_LOG")
  case $actual in
    ''|$'2\tsession\tlist') ;;
    *) add_issue "herdr argv log was $(file_summary "$HERDR_LOG")" ;;
  esac
}

check_fzf_never() {
  if [ -s "$FZF_LOG" ]; then
    add_issue "fzf ran: $(file_summary "$FZF_LOG")"
  fi
}

check_fzf_once() {
  calls=$(awk 'END { print NR + 0 }' "$FZF_LOG")
  if [ "$calls" -ne 1 ]; then
    add_issue "fzf ran $calls times"
  fi
}

check_candidates() {
  for wanted_candidate in "$@"; do
    if ! grep -Fq -- "$wanted_candidate" "$FZF_INPUT"; then
      add_issue "fzf input lacked $wanted_candidate"
    fi
  done
}

check_stderr_empty() {
  if [ -s "$STDERR_FILE" ]; then
    add_issue "stderr was $(file_summary "$STDERR_FILE")"
  fi
}

check_stderr_message() {
  if ! grep -q '[^[:space:]]' "$STDERR_FILE"; then
    add_issue 'stderr was empty'
  elif [ -n "$1" ] && ! grep -Eiq -- "$1" "$STDERR_FILE"; then
    add_issue "stderr did not name the cause: $(file_summary "$STDERR_FILE")"
  fi
}

check_nested_message() {
  lines=$(awk 'END { print NR + 0 }' "$STDERR_FILE")
  if [ "$lines" -ne 1 ]; then
    add_issue "stderr had $lines lines"
  fi
  if ! grep -Eiq '((ctrl|control)[[:space:]_+-]*a.*q|prefix[[:space:]_+-]*q)' "$STDERR_FILE"; then
    add_issue "stderr did not name ctrl+a then q: $(file_summary "$STDERR_FILE")"
  fi
}

check_caller_state() {
  for state_key in SESSION SESSIONS SELECTED_SESSION SELECTED SELECTION CHOICE CANDIDATE CANDIDATES LIST_OUTPUT FZF_STATUS SESSION_LIST LIST_STATUS PICKED PICK NAMES NAME OUTPUT RESULT COMMAND_STATUS FZF_OUTPUT FZF_RESULT HR_STATUS RET RETURN_CODE VALUE LIST_RESULT SESSION_NAME SELECTED_NAME FZF_RC LIST_RC ATTACH_RC; do
    if [[ -n ${STATE_CACHE[$state_key]+present} ]]; then
      actual_value=${STATE_CACHE[$state_key]}
    else
      actual_value='<missing>'
    fi
    expected_value=sentinel:${state_key,,}
    if [ "$actual_value" != "$expected_value" ]; then
      add_issue "$state_key leaked as $actual_value"
    fi
  done
  actual_value=${STATE_CACHE[RC_HELPER]-'<missing>'}
  if [ "$actual_value" != sentinel:rc ]; then
    add_issue "RC helper leaked as $actual_value"
  fi
  actual_value=${STATE_CACHE[IFS_PRESERVED]-'<missing>'}
  if [ "$actual_value" != 1 ]; then
    add_issue 'caller IFS was changed'
  fi
}

defaults() {
  C_MODE=bare
  C_NAME=
  C_INSIDE=0
  C_SET_U=0
  C_SET_E=0
  C_PATH_MODE=normal
  C_LIST_OUTPUT=$'NAME STATE\nalpha running\nbeta stopped\n'
  C_LIST_STATUS=0
  C_LIST_STDERR=
  C_ATTACH_STATUS=0
  C_ATTACH_STDERR=
  C_NAMED_STATUS=0
  C_NAMED_STDERR=
  C_BARE_STATUS=0
  C_BARE_STDERR=
  C_FZF_OUTPUT=$'beta\n'
  C_FZF_STATUS=0
  C_FZF_STDERR=
}

configure_case() {
  defaults
  case $1 in
    source_only)
      C_MODE=source_only
      ;;
    named_success)
      C_MODE=named
      C_NAME=alpha
      ;;
    bare_selection)
      ;;
    nested_named)
      C_MODE=named
      C_NAME=alpha
      C_INSIDE=1
      ;;
    nested_bare)
      C_INSIDE=1
      ;;
    fzf_cancel_130)
      C_FZF_STATUS=130
      C_FZF_OUTPUT=$'beta\n'
      ;;
    fzf_error_2)
      C_FZF_STATUS=2
      C_FZF_OUTPUT=$'beta\n'
      ;;
    fzf_missing)
      C_PATH_MODE=missing
      ;;
    fzf_no_match_1)
      C_FZF_STATUS=1
      C_FZF_OUTPUT=$'beta\n'
      ;;
    list_failure)
      C_LIST_STATUS=37
      C_LIST_OUTPUT=$'NAME STATE\nbeta running\n'
      C_FZF_OUTPUT=$'beta\n'
      ;;
    header_only)
      C_LIST_OUTPUT=$'NAME STATE\n'
      C_FZF_STATUS=0
      C_FZF_OUTPUT=
      ;;
    attach_failure)
      C_ATTACH_STATUS=47
      C_ATTACH_STDERR=$'attach failed\n'
      ;;
    named_failure)
      C_MODE=named
      C_NAME=alpha
      C_NAMED_STATUS=43
      ;;
    nounset_bare)
      C_SET_U=1
      ;;
    errexit_cancel)
      C_SET_E=1
      C_FZF_STATUS=130
      C_FZF_OUTPUT=$'beta\n'
      ;;
    no_variable_leaks)
      ;;
    named_metachar)
      C_MODE=named
      C_NAME='meta;*session'
      ;;
    selected_metachar)
      C_LIST_OUTPUT=$'NAME STATE\npick;*session running\nalpha stopped\n'
      C_FZF_OUTPUT=$'pick;*session\n'
      ;;
    *)
      printf 'test-hr: internal unknown case %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

execute_case() {
  shell_name=$1
  case_name=$2
  RESULT_BASE=$RESULT_DIR/$shell_name-$case_name
  STDOUT_FILE=$RESULT_BASE.stdout
  STDERR_FILE=$RESULT_BASE.stderr
  STATE_FILE=$RESULT_BASE.state
  HERDR_LOG=$RESULT_BASE.herdr
  FZF_LOG=$RESULT_BASE.fzf
  FZF_INPUT=$RESULT_BASE.fzf-input
  : >"$STDOUT_FILE"
  : >"$STDERR_FILE"
  : >"$STATE_FILE"
  : >"$HERDR_LOG"
  : >"$FZF_LOG"
  : >"$FZF_INPUT"

  if [ "$C_PATH_MODE" = missing ]; then
    active_stub=$NO_FZF_BIN
    case_path=$NO_FZF_BIN:$SAFE_BIN
    expected_fzf=missing
  else
    active_stub=$STUB_BIN
    case_path=$STUB_BIN:$SAFE_BIN
    expected_fzf=present
  fi

  if [ "$shell_name" = bash ]; then
    shell_command=("$BASH_BIN" "$RUNNER")
  else
    shell_command=("$ZSH_BIN" -f "$RUNNER")
  fi

  "$ENV_BIN" -i \
  BASH_ENV=/dev/null \
  ENV=/dev/null \
  LC_ALL=C \
  TMPDIR="$CHILD_TMP" \
  PATH="$case_path" \
  HR_TEST_HR_PATH="$HR_FILE" \
  HR_TEST_STATE="$STATE_FILE" \
  HR_TEST_CASE_CWD="$CASE_CWD" \
  HR_TEST_STUB_DIR="$active_stub" \
  HR_TEST_EXPECT_FZF="$expected_fzf" \
  HR_TEST_HERDR_LOG="$HERDR_LOG" \
  HR_TEST_FZF_LOG="$FZF_LOG" \
  HR_TEST_FZF_INPUT="$FZF_INPUT" \
  HR_TEST_MODE="$C_MODE" \
  HR_TEST_NAME="$C_NAME" \
  HR_TEST_INSIDE="$C_INSIDE" \
  HR_TEST_SET_U="$C_SET_U" \
  HR_TEST_SET_E="$C_SET_E" \
  HR_TEST_LIST_OUTPUT="$C_LIST_OUTPUT" \
  HR_TEST_LIST_STATUS="$C_LIST_STATUS" \
  HR_TEST_LIST_STDERR="$C_LIST_STDERR" \
  HR_TEST_ATTACH_STATUS="$C_ATTACH_STATUS" \
  HR_TEST_ATTACH_STDERR="$C_ATTACH_STDERR" \
  HR_TEST_NAMED_STATUS="$C_NAMED_STATUS" \
  HR_TEST_NAMED_STDERR="$C_NAMED_STDERR" \
  HR_TEST_BARE_STATUS="$C_BARE_STATUS" \
  HR_TEST_BARE_STDERR="$C_BARE_STDERR" \
  HR_TEST_FZF_OUTPUT="$C_FZF_OUTPUT" \
  HR_TEST_FZF_STATUS="$C_FZF_STATUS" \
  HR_TEST_FZF_STDERR="$C_FZF_STDERR" \
  "${shell_command[@]}" </dev/null >"$STDOUT_FILE" 2>"$STDERR_FILE"
  CHILD_RC=$?

  STATE_CACHE=()
  while IFS= read -r state_line; do
    case $state_line in
      *=*)
        state_key=${state_line%%=*}
        [ -n "$state_key" ] || continue
        STATE_CACHE["$state_key"]=${state_line#*=}
        ;;
    esac
  done <"$STATE_FILE"

  SHELL_ISSUES=
  if [ "$CHILD_RC" -ne 0 ]; then
    add_issue "case shell exited $CHILD_RC"
  fi
  PREFLIGHT=${STATE_CACHE[PREFLIGHT]-'<missing>'}
  if [ "$PREFLIGHT" != ok ]; then
    add_issue "stub preflight was $PREFLIGHT"
  fi
  DONE=${STATE_CACHE[DONE]-'<missing>'}
  if [ "$DONE" != 1 ]; then
    add_issue 'case did not reach its after-call marker'
  fi
  OBSERVED_RC=${STATE_CACHE[RC]-'<missing>'}
  OBSERVED_OPTIONS=${STATE_CACHE[OPTIONS]-'<missing>'}
}

assert_case() {
  case $1 in
    source_only)
      check_rc 0
      check_herdr_exact ''
      check_fzf_never
      ;;
    named_success)
      check_rc 0
      check_herdr_exact $'2\t--session\talpha'
      check_fzf_never
      ;;
    bare_selection)
      check_rc 0
      check_herdr_exact $'2\tsession\tlist\n3\tsession\tattach\tbeta'
      check_fzf_once
      check_candidates alpha beta
      ;;
    nested_named|nested_bare)
      check_nonzero_rc
      check_herdr_exact ''
      check_fzf_never
      check_nested_message
      ;;
    fzf_cancel_130)
      check_nonzero_rc
      check_herdr_exact $'2\tsession\tlist'
      check_fzf_once
      check_stderr_empty
      ;;
    fzf_error_2)
      check_nonzero_rc
      check_herdr_exact $'2\tsession\tlist'
      check_fzf_once
      check_stderr_message ''
      ;;
    fzf_missing)
      check_nonzero_rc
      check_herdr_empty_or_list
      check_fzf_never
      check_stderr_message ''
      ;;
    fzf_no_match_1)
      check_nonzero_rc
      check_herdr_exact $'2\tsession\tlist'
      check_fzf_once
      ;;
    list_failure)
      check_nonzero_rc
      check_herdr_exact $'2\tsession\tlist'
      check_stderr_message '((list|enumerat|query|retrieve|fetch).*(fail|error|unable|cannot|could|non.?zero|status|exit|return)|(fail|error|unable|cannot|could|non.?zero|status|exit|return).*(list|session|enumerat|query|retrieve|fetch))'
      ;;
    header_only)
      check_nonzero_rc
      check_herdr_exact $'2\tsession\tlist'
      check_stderr_message '(((no|none|nothing|empty|zero|without|unavailable).*(session|name|candidate|entry|choice|item|result|match|select))|((session|name|candidate|entry|choice|item|result|match|list).*(no|none|nothing|empty|zero|unavailable|not found))|(only.*header|header.*only)|((not|cannot|could|unable).*(find|select|choose).*(session|name|candidate|entry|choice|item|result|match)))'
      ;;
    attach_failure)
      check_rc 47
      check_herdr_exact $'2\tsession\tlist\n3\tsession\tattach\tbeta'
      check_fzf_once
      ;;
    named_failure)
      check_nonzero_rc
      check_herdr_exact $'2\t--session\talpha'
      check_fzf_never
      ;;
    nounset_bare)
      check_rc 0
      check_herdr_exact $'2\tsession\tlist\n3\tsession\tattach\tbeta'
      check_fzf_once
      case $OBSERVED_OPTIONS in
        *u*) ;;
        *) add_issue 'caller nounset option was not preserved' ;;
      esac
      check_stderr_empty
      ;;
    errexit_cancel)
      check_nonzero_rc
      check_herdr_exact $'2\tsession\tlist'
      check_fzf_once
      check_stderr_empty
      case $OBSERVED_OPTIONS in
        *e*) ;;
        *) add_issue 'caller errexit option was not preserved' ;;
      esac
      ;;
    no_variable_leaks)
      check_rc 0
      check_herdr_exact $'2\tsession\tlist\n3\tsession\tattach\tbeta'
      check_fzf_once
      ;;
    named_metachar)
      check_rc 0
      check_herdr_exact $'2\t--session\tmeta;*session'
      check_fzf_never
      ;;
    selected_metachar)
      check_rc 0
      check_herdr_exact $'2\tsession\tlist\n3\tsession\tattach\tpick;*session'
      check_fzf_once
      check_candidates 'pick;*session' alpha
      ;;
  esac
  if [ "$DONE" = 1 ]; then
    check_caller_state
  fi
}

case_expectation() {
  case $1 in
    source_only) printf 'sourcing defines hr without executing either binary' ;;
    named_success) printf 'named launch passes exactly --session alpha and returns 0' ;;
    bare_selection) printf 'list, fzf selection, and exact attach succeed' ;;
    nested_named) printf 'nested named call is blocked with the ctrl+a q detach hint' ;;
    nested_bare) printf 'nested bare call is blocked with the ctrl+a q detach hint' ;;
    fzf_cancel_130) printf 'fzf cancellation is quiet and launches nothing' ;;
    fzf_error_2) printf 'fzf error is reported and launches nothing' ;;
    fzf_missing) printf 'missing fzf is reported without reaching a real binary' ;;
    fzf_no_match_1) printf 'fzf no-match launches nothing and returns non-zero' ;;
    list_failure) printf 'a failed list is reported even when it emitted usable data' ;;
    header_only) printf 'a header-only list is reported and launches nothing' ;;
    attach_failure) printf 'attach status 47 is propagated without a bare fallback' ;;
    named_failure) printf 'a failed named launch remains non-zero without fallback' ;;
    nounset_bare) printf 'bare hr succeeds and preserves caller nounset' ;;
    errexit_cancel) printf 'guarded cancellation returns and preserves caller errexit' ;;
    no_variable_leaks) printf 'all preset helper-name sentinels remain unchanged' ;;
    named_metachar) printf 'a named glob metacharacter remains one literal argument' ;;
    selected_metachar) printf 'a selected glob metacharacter remains one literal argument' ;;
  esac
}

CASES='source_only
named_success
bare_selection
nested_named
nested_bare
fzf_cancel_130
fzf_error_2
fzf_missing
fzf_no_match_1
list_failure
header_only
attach_failure
named_failure
nounset_bare
errexit_cancel
no_variable_leaks
named_metachar
selected_metachar'

passed=0
failed=0
total=0
while IFS= read -r case_name; do
  [ -n "$case_name" ] || continue
  total=$((total + 1))
  combined_issues=
  for shell_name in bash zsh; do
    configure_case "$case_name"
    execute_case "$shell_name" "$case_name"
    assert_case "$case_name"
    if [ -n "$SHELL_ISSUES" ]; then
      if [ -n "$combined_issues" ]; then
        combined_issues="$combined_issues; $shell_name: $SHELL_ISSUES"
      else
        combined_issues="$shell_name: $SHELL_ISSUES"
      fi
    fi
  done
  expectation=$(case_expectation "$case_name")
  if [ -z "$combined_issues" ]; then
    passed=$((passed + 1))
    printf 'PASS %s — expected %s vs observed matching behavior in bash + zsh\n' "$case_name" "$expectation"
  else
    failed=$((failed + 1))
    printf 'FAIL %s — expected %s vs observed %s\n' "$case_name" "$expectation" "$combined_issues"
  fi
done <<<"$CASES"

printf 'RESULT %s passed, %s failed, %s total (%s shell executions)\n' \
  "$passed" "$failed" "$total" "$((total * 2))"
[ "$failed" -eq 0 ]
