# Codex Shared-Skills Probe — Detecting Description Truncation

Load when the number of skills under `~/.agents/skills` grows, or when you check which skills Codex lists with `codex debug prompt-input`.

Codex reads `$HOME/.agents/skills` and `<repo>/.agents/skills`. When the skill list exceeds its context budget it shortens every description to about 400 characters and prints no warning, so "all skills are listed" proves nothing about whether the descriptions arrived in full.

## Probe

1. `codex debug prompt-input x > out.json` prints one JSON-escaped string. Parse the JSON, then match `- <name>: <description> (file: <path>)` per line. A line-anchored `grep` on the raw output miscounts because the newlines are escaped.
2. Compare each description's length with the SKILL.md frontmatter. Many skills capped at the same length (about 400) means truncation. A missing warning is not evidence of full text.
3. Check the longest descriptions by name (2026-10-02: `self-heal-resolve` 621 characters, `verify-mise-backend` 607). Both must appear at full length.

## Measured on 2026-10-02 (codex-cli 0.159.3)

- 118 shared skills exceeded the default skills budget by about 900 B. Full descriptions need about 6000 tokens.
- The fix is `[skills] max_context_tokens = 8000` in `cookbooks/codex-cli/files/generate_config.sh` (line 71, e97c54f). With it, the probe lists 118 skills, a maximum description of 621 characters, and no budget warning.
- Re-measure whenever skills are added. The 8000 limit leaves about 2000 tokens of headroom over the 6000 needed.

## Temp-HOME probe: enumeration only

`HOME=<dir> CODEX_HOME=<dir>/.codex codex debug prompt-input x` confirms that Codex finds skills placed under `<dir>/.agents/skills`. The first temp-HOME run listed 121 skills with 0 warnings and was read as "all fit", which was wrong: it did not measure description length. Use temp-HOME for enumeration only, and measure length on the real HOME. Whether truncation also occurred in that temp-HOME run is unmeasured [推測].

## Worktree-isolated sessions

Inline `HOME=... codex ...` is refused there. Put the probe in a script file and run its path.
