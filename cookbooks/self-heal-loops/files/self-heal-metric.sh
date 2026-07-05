#!/usr/bin/env bash
#
# self-heal-metric.sh — node_exporter textfile liveness metric for the self-heal
# create/resolve loop wrappers. Managed by cookbooks/self-heal-loops. Do not edit
# by hand. SOURCED (not executed) by the two run wrappers.
#
# emit_loop_metric <loop: create|resolve> <result: ok|error|auth>
#   Writes, for the given loop:
#     self_heal_loop_last_run_timestamp_seconds{loop="…"}  <unix-now>
#     self_heal_loop_status{loop="…",result="ok|error|auth"} 1/0
#   to ${SELF_HEAL_TEXTFILE_DIR}/self-heal-<loop>.prom (per-loop file so the two
#   crons never race on one file).
#
# Write model: the loop runs as a non-root user (runuser -l shin1ohno) and OWNS
# the .prom FILE (the cookbook pre-creates it loop-user-owned) but NOT the
# root-owned textfile DIR. tmp+rename is therefore unavailable; a single printf
# redirection of this small payload is the most-atomic option, and node-exporter
# self-corrects a rare partial read on the next scrape. Best-effort throughout:
# never fails the caller (the wrapper must exit 0 for the cron liveness signal).

SELF_HEAL_TEXTFILE_DIR="${SELF_HEAL_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"

emit_loop_metric() {
  local loop="${1:-}" result="${2:-ok}"
  local now file content ok_v err_v auth_v
  [ -n "${loop}" ] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  file="${SELF_HEAL_TEXTFILE_DIR}/self-heal-${loop}.prom"

  [ "${result}" = "ok" ]    && ok_v=1   || ok_v=0
  [ "${result}" = "error" ] && err_v=1  || err_v=0
  [ "${result}" = "auth" ]  && auth_v=1 || auth_v=0

  printf -v content '%s\n' \
    "# HELP self_heal_loop_last_run_timestamp_seconds Unix time the self-heal loop last completed a cycle." \
    "# TYPE self_heal_loop_last_run_timestamp_seconds gauge" \
    "self_heal_loop_last_run_timestamp_seconds{loop=\"${loop}\"} ${now}" \
    "# HELP self_heal_loop_status Result of the self-heal loop's last cycle (1 = this result active)." \
    "# TYPE self_heal_loop_status gauge" \
    "self_heal_loop_status{loop=\"${loop}\",result=\"ok\"} ${ok_v}" \
    "self_heal_loop_status{loop=\"${loop}\",result=\"error\"} ${err_v}" \
    "self_heal_loop_status{loop=\"${loop}\",result=\"auth\"} ${auth_v}"

  # Single write() of the assembled buffer (see header for why not tmp+rename).
  printf '%s' "${content}" > "${file}" 2>/dev/null || true
  return 0
}
