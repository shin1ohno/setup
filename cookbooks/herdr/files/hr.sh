# `hr` — herdr session launcher. Deployed to
# ~/.setup_shin1ohno/profile.d/50-herdr-hr.sh by cookbooks/herdr; sourced by
# interactive zsh and bash. Regression suite: cookbooks/herdr/files/test-hr.sh.
#
# Every failure path returns non-zero and launches NOTHING. Earlier versions
# ended in `… && attach || herdr`, which turned an fzf cancel, an fzf error, a
# failed `session list` and a failed attach alike into "the default session
# opened", hiding the cause.
hr() {
  local _hr_list _hr_names _hr_pick _hr_rc
  if [ "${HERDR_ENV-}" = 1 ]; then
    printf '%s\n' 'hr: already inside herdr; press ctrl+a then q to detach, then retry' >&2
    return 1
  fi
  if [ -n "${1-}" ]; then
    herdr --session "$1" || return $?
    return 0
  fi
  if _hr_list=$(herdr session list 2>/dev/null); then
    :
  else
    _hr_rc=$?
    printf 'hr: herdr session list failed (status %s)\n' "$_hr_rc" >&2
    return "$_hr_rc"
  fi
  _hr_names=$(printf '%s\n' "$_hr_list" | awk 'NR > 1 && NF { print $1 }')
  if [ -z "$_hr_names" ]; then
    printf '%s\n' 'hr: herdr session list returned no session names' >&2
    return 1
  fi
  if _hr_pick=$(printf '%s\n' "$_hr_names" | fzf --exit-0 2>/dev/null); then
    :
  else
    _hr_rc=$?
    case "$_hr_rc" in
      1|130) return "$_hr_rc" ;;
      *) printf 'hr: fzf failed (status %s)\n' "$_hr_rc" >&2; return "$_hr_rc" ;;
    esac
  fi
  if [ -z "$_hr_pick" ]; then
    printf '%s\n' 'hr: fzf returned no session' >&2
    return 1
  fi
  herdr session attach "$_hr_pick"
}
