#!/usr/bin/env bash
#
# Build Cowork-uploadable skill packages from 03-skills/.
#
#   Output : zips-ready/<skill>.zip   (gitignored — see repo .gitignore)
#   Source : 03-skills/<skill>/SKILL.md (+ any referenced files)
#
# Packaging follows the official Anthropic skill-creator packager
# (skill-creator/scripts/package_skill.py):
#   - each zip wraps the skill FOLDER at top level → <skill>/SKILL.md
#   - excludes .DS_Store / __pycache__ / *.pyc and a top-level evals/ dir
#   - every SKILL.md frontmatter is validated before packaging
#     (kebab-case name <=64 chars; description present, no <> , <=1024 chars;
#      only name/description/license/allowed-tools/metadata/compatibility keys)
#
# Layout toggle (Cowork's uploader acceptance is the one thing this script
# cannot self-verify — flip with one env var if the wrapped form is rejected):
#   LAYOUT=wrapped (default) → zip contains <skill>/SKILL.md   (official)
#   LAYOUT=flat              → zip contains SKILL.md at root    (migration-guide form)
#
# Usage:
#   ./build-skills.sh                 # build all skills, wrapped layout
#   LAYOUT=flat ./build-skills.sh     # build all skills, flat layout
#   ./build-skills.sh writing research # build only the named skills
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/03-skills"
OUT="$HERE/zips-ready"
LAYOUT="${LAYOUT:-wrapped}"

# --- precondition guards (self-diagnosing) ---------------------------------
command -v zip >/dev/null 2>&1 || { echo "ERROR: 'zip' not found on PATH." >&2; exit 1; }
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "ERROR: python3 not found (needed for frontmatter validation)." >&2; exit 1; }
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "ERROR: python 'yaml' module missing. Install: pip install pyyaml" >&2; exit 1; }
case "$LAYOUT" in wrapped|flat) ;; *) echo "ERROR: LAYOUT must be 'wrapped' or 'flat' (got '$LAYOUT')." >&2; exit 1;; esac

# --- frontmatter validator (official quick_validate rules) -----------------
validate() {
  "$PY" - "$1" <<'PYEOF'
import re, sys, yaml
from pathlib import Path
p = Path(sys.argv[1]) / "SKILL.md"
if not p.exists():
    sys.exit("SKILL.md not found")
c = p.read_text()
if not c.startswith("---"):
    sys.exit("No YAML frontmatter")
m = re.match(r"^---\n(.*?)\n---", c, re.DOTALL)
if not m:
    sys.exit("Invalid frontmatter format")
try:
    fm = yaml.safe_load(m.group(1))
except yaml.YAMLError as e:
    sys.exit(f"Invalid YAML: {e}")
if not isinstance(fm, dict):
    sys.exit("Frontmatter must be a YAML dict")
allowed = {"name", "description", "license", "allowed-tools", "metadata", "compatibility"}
extra = set(fm) - allowed
if extra:
    sys.exit("Unexpected key(s): " + ", ".join(sorted(extra)))
name = (fm.get("name") or "").strip()
if not name:
    sys.exit("Missing 'name'")
if not re.match(r"^[a-z0-9-]+$", name) or name.startswith("-") or name.endswith("-") or "--" in name:
    sys.exit(f"name '{name}' must be kebab-case")
if len(name) > 64:
    sys.exit("name too long (>64)")
desc = (fm.get("description") or "").strip()
if not desc:
    sys.exit("Missing 'description'")
if "<" in desc or ">" in desc:
    sys.exit("description contains angle brackets")
if len(desc) > 1024:
    sys.exit(f"description too long ({len(desc)}>1024)")
PYEOF
}

mkdir -p "$OUT"

# --- which skills to build -------------------------------------------------
if [ "$#" -gt 0 ]; then
  skills=("$@")
else
  skills=()
  for d in "$SRC"/*/; do skills+=("$(basename "$d")"); done
fi

built=0
for skill in "${skills[@]}"; do
  dir="$SRC/$skill"
  if [ ! -f "$dir/SKILL.md" ]; then
    echo "SKIP  $skill (no SKILL.md at $dir)" >&2
    continue
  fi
  if ! msg="$(validate "$dir")"; then
    echo "INVALID $skill: $msg" >&2
    exit 1
  fi
  zipfile="$OUT/$skill.zip"
  rm -f "$zipfile"
  if [ "$LAYOUT" = "wrapped" ]; then
    ( cd "$SRC" && zip -rqX "$zipfile" "$skill" \
        -x '*.DS_Store' '*/__pycache__/*' '*.pyc' "$skill/evals/*" )
  else
    ( cd "$dir" && zip -rqX "$zipfile" . \
        -x '*.DS_Store' '*/__pycache__/*' '*.pyc' 'evals/*' )
  fi
  files=$(unzip -Z1 "$zipfile" | wc -l | tr -d ' ')
  echo "built $skill.zip  ($files files, layout=$LAYOUT)"
  built=$((built + 1))
done

echo "----"
echo "Done: $built skill(s) → $OUT  (layout=$LAYOUT)"
