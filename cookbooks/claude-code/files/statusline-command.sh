#!/usr/bin/env bash
set -euo pipefail

input=$(cat)

# --- Parse JSON from stdin ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Context size = sum of all input token categories from the last API call.
# `input_tokens` alone excludes cache hits, which dominate cached turns and
# make the value read near 0. Summing all three reflects the actual state.
used=$(echo "$input" | jq -r '
  if .context_window.current_usage then
    (.context_window.current_usage.input_tokens // 0)
    + (.context_window.current_usage.cache_creation_input_tokens // 0)
    + (.context_window.current_usage.cache_read_input_tokens // 0)
  else
    empty
  end
')
total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# --- Derive git branch ---
branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

# --- Derive PR number (best-effort, cached 60s per branch) ---
pr_num=""
if [ -n "$branch" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ] && [ "$branch" != "HEAD" ]; then
  cache_dir="${XDG_RUNTIME_DIR:-/tmp}/claude-statusline-pr"
  mkdir -p "$cache_dir" 2>/dev/null || true
  cache_key=$(printf "%s-%s" "$cwd" "$branch" | tr '/ ' '__')
  cache_file="$cache_dir/$cache_key.num"

  if [ -f "$cache_file" ] && [ "$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))" -lt 60 ]; then
    pr_num=$(cat "$cache_file" 2>/dev/null || true)
  elif command -v gh >/dev/null 2>&1; then
    pr_num=$(cd "$cwd" && timeout 2s gh pr view --json number --jq .number 2>/dev/null || true)
    printf "%s" "$pr_num" > "$cache_file" 2>/dev/null || true
  fi
fi

# --- Build output ---
# Header group: model, dir, branch — joined by spaces.
# Metric group: ctx, lines, pr — joined by " | " and appended after header.
header=""
[ -n "$model" ] && header="[$model]"
[ -n "$cwd" ] && header="${header:+$header }$(basename "$cwd")"
[ -n "$branch" ] && header="${header:+$header }🌿 $branch"

metrics=()
if [ -n "$used" ] && [ -n "$total" ]; then
  used_k=$(awk "BEGIN { printf \"%.0f\", $used / 1000 }")
  total_k=$(awk "BEGIN { printf \"%.0f\", $total / 1000 }")
  metrics+=("ctx: ${used_k}k/${total_k}k")
else
  metrics+=("ctx: --")
fi

if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
  metrics+=("+${lines_added} -${lines_removed}")
fi

[ -n "$pr_num" ] && metrics+=("#$pr_num")

# Join metrics with " | " (IFS uses a single char; join manually).
metrics_joined=""
for i in "${!metrics[@]}"; do
  if [ "$i" -eq 0 ]; then
    metrics_joined="${metrics[$i]}"
  else
    metrics_joined="$metrics_joined | ${metrics[$i]}"
  fi
done

if [ -n "$header" ] && [ -n "$metrics_joined" ]; then
  printf "%s | %s" "$header" "$metrics_joined"
elif [ -n "$header" ]; then
  printf "%s" "$header"
else
  printf "%s" "$metrics_joined"
fi
