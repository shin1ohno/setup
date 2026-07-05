---
name: apply-cookbook
description: >-
  Interactively pick one cookbook from this setup repo and apply it to the
  local machine via the single-cookbook test harness, with a dependency/
  prerequisite preview and a mandatory dry-run before the real apply. Use when
  the user asks to "apply a cookbook", "apply cookbook", "run a cookbook",
  "cookbook 適用", "cookbook を選んで適用", "cookbook を適用したい",
  "pick a cookbook to apply", or names a cookbook to converge locally
  (e.g. "apply the mise cookbook"). Localhost only — remote/fleet apply
  (bin/apply-pve-lxcs) is out of scope.
user-invocable: true
allowed-tools: ["Bash", "AskUserQuestion"]
---

# Apply Cookbook Skill

## Purpose

Let the user apply a single cookbook to the **local** machine without hand-writing
the `COOKBOOK=<name> ./bin/mitamae local test-cookbook.rb` invocation. The skill
narrows 140 cookbooks down to one via a search term, blocks obvious
OS-mismatches, previews the dependency closure + external prerequisites, and
always runs a dry-run for confirmation before the real apply.

This is a runtime convenience for the machine you are on. It is NOT for
remote/fleet apply (`bin/apply-pve-lxcs`), role-level apply, or multi-cookbook
apply — those are out of scope.

## Preconditions

1. **Repo root.** Resolve the setup repo and run every command from its root:

   ```bash
   REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
   { [ -n "$REPO" ] && [ -f "$REPO/test-cookbook.rb" ] && [ -d "$REPO/cookbooks" ]; } || REPO="$HOME/ManagedProjects/setup"
   ```

   If `$REPO/test-cookbook.rb` still does not exist, stop and tell the user the
   setup repo could not be located.

2. **Sandbox.** The `mitamae ... --dry-run` and real-apply Bash calls MUST run
   with `dangerouslyDisableSandbox: true`. mitamae's `remote_file` probes
   writability with `touch /tmp/<rand>`, which the command sandbox denies
   (`touch: /tmp/...: Operation not permitted`) — it aborts on the first
   `remote_file` of an unrelated baseline cookbook before reaching the one under
   test. Read-only steps (ls / grep / probes) do not need this.

3. **No sudo on the outer invocation.** Run `./bin/mitamae local test-cookbook.rb`
   as the regular user. Never prepend `sudo` — it rewrites `$HOME` to `/root`
   and breaks mise/rbenv/pyenv PATH resolution. Privileged steps escalate
   per-resource inside the cookbook via `execute "sudo ..."`, which prompts
   interactively. (The `.claude/hooks/guard-mitamae-dry-run.rb` guard only
   forces `--dry-run` on `sudo mitamae`; a bare `./bin/mitamae local` passes.)

## Workflow

### 1. Get the search term

Take the search term from the skill argument or the user's message. If there is
none, ask first — do not guess:

> どの cookbook を適用しますか?（検索語 or cookbook 名）

### 2. Filter cookbooks by the search term (substring, case-insensitive)

```bash
ls -d "$REPO"/cookbooks/*/ | xargs -n1 basename | grep -i -- "<term>"
```

### 3. Branch on the hit count → one confirmed cookbook

- **0 hits** — report "該当なし" and ask for a different term. Do not proceed.
- **1 hit** — that is the pick; continue to step 4.
- **2–4 hits** — use **AskUserQuestion** (single-select, one option per hit) to
  let the user choose exactly one.
- **5+ hits** — do NOT dump all of them into AskUserQuestion (max 4 options).
  Report the count and the first few names, and ask the user to narrow with a
  more specific term, then re-run step 2.

Store the chosen name as `PICK`.

### 4. OS-guard hard block (selected cookbook's own guard)

Detect the current OS and the cookbook's self-guard; if they conflict, **block
and stop** — do not dry-run or apply.

```bash
UNAME="$(uname)"   # Darwin | Linux
GUARD="$(grep -oE 'return (if|unless) node\[:platform\] (==|!=) "darwin"' "$REPO/cookbooks/$PICK/default.rb" | head -1)"
```

Classify `GUARD`:

| Guard line | Cookbook targets | Block when |
|---|---|---|
| `return if node[:platform] != "darwin"` | darwin-only | `UNAME` = Linux |
| `return unless node[:platform] == "darwin"` | darwin-only | `UNAME` = Linux |
| `return if node[:platform] == "darwin"` | linux-only | `UNAME` = Darwin |
| `return unless node[:platform] != "darwin"` | linux-only | `UNAME` = Darwin |
| (no match) | cross-platform / dual-branch | never block here |

On a block, tell the user which OS the cookbook targets vs the current OS, and
stop.

**Known blind spot (do not silently ignore):** a few linux-only cookbooks
(`bluez`, `broadcom-wifi`, `zeroconf`) carry **no** self-guard — `linux.rb`
limits them by include alone, so this grep cannot detect them and cannot
pre-block them on darwin. The always-on dry-run in step 6 is the safety net:
its converge plan / errors surface before any real apply. When `PICK` is one of
those and `UNAME` = Darwin, note the risk explicitly and lean on the dry-run.

### 5. Dependency + prerequisite preview (inform — not a gate)

Before the dry-run, resolve what else will run and what it needs, so the user
decides yes/no with the blast radius in view. This step adds **no** new hard
block — the only OS block is step 4's self-guard check.

Run this read-only preview (plain `bash`, no sandbox change needed). `REPO`
and `PICK` are passed as env so the quoted heredoc needs no shell escaping; the
body is bash-3.2 safe (no associative arrays) so it also works on stock macOS
`/bin/bash`:

```bash
REPO="$REPO" PICK="$PICK" bash <<'EOF'
# --- A. include-cookbook closure (level-BFS, string-membership dedup + cycle guard) ---
seen=""; todo="$PICK"
while [ -n "$todo" ]; do
  next=""
  for c in $todo; do
    case " $seen " in *" $c "*) continue ;; esac
    seen="$seen $c"
    f="$REPO/cookbooks/$c/default.rb"; [ -f "$f" ] || continue
    for dep in $(grep -oE 'include_cookbook "[a-z0-9_-]+"' "$f" 2>/dev/null | sed -E 's/.*"([a-z0-9_-]+)".*/\1/'); do
      case " $seen $next " in *" $dep "*) ;; *) next="$next $dep" ;; esac
    done
  done
  todo="$next"
done
echo "CLOSURE:$seen"

# --- B. per-closure OS-guard mismatches (self-skip note, NOT a block) ---
# darwin-only iff exactly one of {operator is !=, keyword is unless} (XOR); else linux-only.
UNAME="$(uname)"
for c in $seen; do
  g="$(grep -oE 'return (if|unless) node\[:platform\] (==|!=) "darwin"' "$REPO/cookbooks/$c/default.rb" 2>/dev/null | head -1)"
  [ -z "$g" ] && continue
  kw="$(printf '%s' "$g" | grep -oE 'if|unless' | head -1)"
  op="$(printf '%s' "$g" | grep -oE '==|!=' | head -1)"
  if { [ "$op" = "!=" ] && [ "$kw" = "if" ]; } || { [ "$op" = "==" ] && [ "$kw" = "unless" ]; }; then tgt=darwin; else tgt=linux; fi
  if [ "$tgt" = darwin ] && [ "$UNAME" != Darwin ]; then echo "SELF-SKIP: $c targets darwin (guard self-skips on this host)"; fi
  if [ "$tgt" = linux ]  && [ "$UNAME" = Darwin ];  then echo "SELF-SKIP: $c targets linux (guard self-skips on this host)";  fi
done

# --- C. external auth + tool prerequisites across the closure ---
for c in $seen; do
  f="$REPO/cookbooks/$c/default.rb"; [ -f "$f" ] || continue
  grep -oE 'tool_name: *"[^"]+"' "$f" | sed -E 's/.*"([^"]+)".*/EXT-AUTH: '"$c"' needs \1/'
  grep -q 'mise_tool' "$f" && echo "PREREQ: $c uses mise (mise_tool)"
  grep -qE 'brew_(formula|cask)\?|include_cookbook "homebrew"' "$f" && echo "PREREQ: $c uses homebrew"
done

# --- probes (read-only) ---
echo "PROBE: brew=$(command -v brew || echo -) gh=$(command -v gh || echo -) mise=$(command -v mise || echo -) aws=$(command -v aws || echo -)"
echo "PROBE: ~/.aws/config $( [ -f "$HOME/.aws/config" ] && echo present || echo absent )"
EOF
```

Summarize for the user:

- **適用対象**: `PICK` + closure deps. Note that `test-cookbook.rb` always pulls
  in `functions` / `host-profile` as baseline (one line — not part of the grep
  closure).
- **SELF-SKIP** lines: those deps will no-op on this host via their own guard.
- **EXT-AUTH** lines: external auth needed. In a **non-TTY** run the gate is
  *skipped* (its work silently doesn't happen) — flag this when a probe shows
  the tool/`~/.aws/config` is absent.
- **PREREQ** / **PROBE** lines: brew/mise/gh/aws availability.

The final behavioral confirmation is the dry-run; this preview just front-loads
blast radius + missing-prereq awareness.

### 6. Dry-run (mandatory, sandbox disabled)

```bash
COOKBOOK="$PICK" "$REPO/bin/mitamae" local test-cookbook.rb --dry-run
```

Run this from `$REPO` with `dangerouslyDisableSandbox: true`. Summarize the
converge plan (resources that would change, any errors). If the dry-run errors
out, report it and stop — do not apply.

### 7. Confirm the real apply (AskUserQuestion)

Ask yes/no: apply `PICK` for real now? Include a one-line reminder that
privileged steps will prompt for sudo interactively.

### 8. Apply (only on yes, sandbox disabled, no sudo)

```bash
COOKBOOK="$PICK" "$REPO/bin/mitamae" local test-cookbook.rb
```

Run from `$REPO` with `dangerouslyDisableSandbox: true`, no `sudo` prefix.

### 9. Report

Summarize what converged (created/updated resources) and any errors. If the
apply failed partway, say which resource failed and surface the error — do not
report success without the converge evidence.

## Invariants

- One cookbook per run; localhost only; no `sudo` on the outer invocation.
- The only hard block is step 4 (selected cookbook's self OS-guard). Dependency
  and prerequisite findings are informational.
- Dry-run always precedes a real apply, and both run sandbox-disabled.
