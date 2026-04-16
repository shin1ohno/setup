#!/usr/bin/env bash
set -euo pipefail

input=$(cat)

used=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // empty')
total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

if [ -n "$used" ] && [ -n "$total" ]; then
  used_k=$(awk "BEGIN { printf \"%.0f\", $used / 1000 }")
  total_k=$(awk "BEGIN { printf \"%.0f\", $total / 1000 }")
  printf "ctx: %sk/%sk" "$used_k" "$total_k"
else
  printf "ctx: --"
fi
