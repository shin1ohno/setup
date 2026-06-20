#!/usr/bin/env bash
# Generate Google Workspace CLI (gws) Agent Skills from the INSTALLED gws
# binary and sync them into the Claude Code skills directory.
#
# Generated, not vendored: the skill set always matches the installed gws
# version, so a mise version bump regenerates the skills on the next apply
# instead of drifting from a committed snapshot.
#
# `gws generate-skills` writes to ./skills + ./docs/skills.md relative to CWD
# (it has no output-dir flag), so we run it in a scratch dir and copy the
# result. Only gws-managed skills (gws-*, persona-*, recipe-*) are touched;
# first-party skills that share ~/.claude/skills are left alone. Skills that
# disappear from a newer gws version are pruned by prefix.
set -euo pipefail

SKILLS_DIR="${1:?usage: sync-skills.sh <claude-skills-dir>}"
export PATH="${HOME}/.local/share/mise/shims:${PATH}"

if ! command -v gws >/dev/null 2>&1; then
  echo "sync-skills: gws not found on PATH (looked in ~/.local/share/mise/shims)" >&2
  exit 1
fi

gws_version() { gws --version 2>/dev/null | awk 'NR==1 {print $2}'; }
GWS_VER="$(gws_version)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

( cd "$WORK" && gws generate-skills >/dev/null 2>&1 )

if [ ! -d "$WORK/skills" ]; then
  echo "sync-skills: 'gws generate-skills' produced no skills/ directory" >&2
  exit 1
fi

mkdir -p "$SKILLS_DIR"

# Replace each generated skill dir wholesale (idempotent: identical content
# is just re-copied).
for d in "$WORK"/skills/*/; do
  name="$(basename "$d")"
  rm -rf "${SKILLS_DIR:?}/${name}"
  cp -R "$d" "${SKILLS_DIR}/${name}"
done

# Prune gws-managed skills that no longer exist in the current gws version.
# Scoped to the three gws-owned prefixes so first-party skills are never touched.
shopt -s nullglob
for existing in "$SKILLS_DIR"/gws-* "$SKILLS_DIR"/persona-* "$SKILLS_DIR"/recipe-*; do
  [ -d "$existing" ] || continue
  name="$(basename "$existing")"
  [ -d "$WORK/skills/$name" ] || rm -rf "$existing"
done

printf '%s\n' "$GWS_VER" > "$SKILLS_DIR/.gws-skills-version"
echo "sync-skills: deployed $(find "$WORK"/skills -mindepth 1 -maxdepth 1 -type d | wc -l) gws skills (v${GWS_VER}) to ${SKILLS_DIR}"
