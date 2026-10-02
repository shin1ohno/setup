#!/usr/bin/env bash
# Generate Google Workspace CLI (gws) Agent Skills from the INSTALLED gws
# binary into ~/.agents/skills (the directory Codex reads) and link each one
# into ~/.claude/skills (Claude Code does not read ~/.agents/skills).
#
# Generated, not vendored: the skill set always matches the installed gws
# version, so a mise version bump regenerates the skills on the next apply
# instead of drifting from a committed snapshot.
#
# `gws generate-skills` writes to ./skills + ./docs/skills.md relative to CWD
# (it has no output-dir flag), so we run it in a scratch dir and copy the
# result. Only gws-managed skills (gws-*, persona-*, recipe-*) are touched;
# first-party skills in either directory are left alone. Skills that
# disappear from a newer gws version are pruned by prefix from both.
set -euo pipefail

AGENTS_DIR="${1:?usage: sync-skills.sh <agents-skills-dir> <claude-skills-dir>}"
CLAUDE_DIR="${2:?usage: sync-skills.sh <agents-skills-dir> <claude-skills-dir>}"
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

mkdir -p "$AGENTS_DIR" "$CLAUDE_DIR"

# Replace each generated skill dir wholesale (idempotent: identical content
# is just re-copied), then point ~/.claude/skills/<name> at it. The rm -rf on
# the Claude path removes either a previous symlink or the real directory an
# older version of this script left there; without it ln -s would nest the new
# link inside that directory.
for d in "$WORK"/skills/*/; do
  name="$(basename "$d")"
  rm -rf "${AGENTS_DIR:?}/${name}"
  cp -R "$d" "${AGENTS_DIR}/${name}"
  rm -rf "${CLAUDE_DIR:?}/${name}"
  ln -s "${AGENTS_DIR}/${name}" "${CLAUDE_DIR}/${name}"
done

# Prune gws-managed skills that no longer exist in the current gws version.
# Scoped to the three gws-owned prefixes so first-party skills are never touched.
# -L as well as -d: a link whose target was just pruned is dangling and fails -d.
shopt -s nullglob
for root in "$AGENTS_DIR" "$CLAUDE_DIR"; do
  for existing in "$root"/gws-* "$root"/persona-* "$root"/recipe-*; do
    [ -d "$existing" ] || [ -L "$existing" ] || continue
    name="$(basename "$existing")"
    [ -d "$WORK/skills/$name" ] || rm -rf "$existing"
  done
done

# The sentinel used to live beside the Claude skills; drop the stale copy.
rm -f "$CLAUDE_DIR/.gws-skills-version"
printf '%s\n' "$GWS_VER" > "$AGENTS_DIR/.gws-skills-version"
echo "sync-skills: deployed $(find "$WORK"/skills -mindepth 1 -maxdepth 1 -type d | wc -l) gws skills (v${GWS_VER}) to ${AGENTS_DIR}, linked into ${CLAUDE_DIR}"
