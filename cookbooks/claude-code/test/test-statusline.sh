#!/usr/bin/env bash
# Regression test for the coralline statusline cost (refreshInterval + forks per run).
# Usage: bash cookbooks/claude-code/test/test-statusline.sh   (needs jq, git)
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.claude/coralline/themes"
cp "$here/files/coralline/statusline.sh" "$work/.claude/coralline/statusline.sh"
cp "$here/files/coralline/themes/"*.conf "$work/.claude/coralline/themes/"
# HOME stays real (jq may be a mise shim resolved through it); only the config and theme are pinned.
sed "s#\$HOME/.claude/coralline/themes#$work/.claude/coralline/themes#" "$here/files/coralline/coralline.conf" > "$work/.claude/coralline.conf"
export CORALLINE_CONFIG="$work/.claude/coralline.conf"
repo="$work/repo"; git init -q -b main "$repo"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
input=$(jq -nc --arg d "$repo" '{workspace:{current_dir:$d},model:{display_name:"Sonnet 5.5"},
  cost:{total_cost_usd:1.23,total_duration_ms:600000,total_lines_added:10,total_lines_removed:2},
  context_window:{used_percentage:42},effort:{level:"high"},thinking:{enabled:true}}')

raw=$(printf "%s" "$input" | COLUMNS=300 bash "$work/.claude/coralline/statusline.sh"); out=$(printf "%s" "$raw" | sed -E "s/\x1b\[[0-9;]*m//g")
for f in "repo" "main" "Sonnet 5.5" "high" "42%" '$1.23' "+10" "-2" "10m" "⊙ "; do
  case "$out" in *"$f"*) ok "field shown: $f" ;; *) bad "field missing: $f in: $out" ;; esac
done
printf '%s' "$out" | grep -Eq '⊙ [0-9]{2}:[0-9]{2} ' && ok "clock is HH:MM" || bad "clock is not HH:MM"

# refreshInterval: the cookbook value must be >= 10 and the static settings.json must agree.
rb=$(sed -n 's/.*"refreshInterval" => \([0-9]*\),.*/\1/p' "$here/default.rb")
js=$(jq -r '.statusLine.refreshInterval' "$here/files/settings.json")
[ "${rb:-0}" -ge 10 ] && ok "default.rb refreshInterval=$rb" || bad "default.rb refreshInterval=$rb (<10)"
[ "$rb" = "$js" ] && ok "settings.json refreshInterval matches" || bad "settings.json=$js default.rb=$rb"

# Fork budget per run: bash subshells + no `date` exec (clock uses printf %()T on bash>=4.2).
t="$work/xtrace"
printf '%s' "$input" | COLUMNS=300 PS4='+${BASHPID}:' bash -x "$work/.claude/coralline/statusline.sh" 2>"$t" >/dev/null
subs=$(( $(grep -oE '^\++[0-9]+:' "$t" | sort -u | wc -l) - 1 ))
[ "$subs" -le 75 ] && ok "subshell forks per run: $subs (<=75)" || bad "subshell forks per run: $subs (>75)"
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  grep -qE '^\++[0-9]+:date ' "$t" && bad "date was exec'd" || ok "no date exec"
fi
exit "$fail"
