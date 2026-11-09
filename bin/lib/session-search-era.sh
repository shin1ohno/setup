#!/bin/bash
# Shared pin/manifest grammar and history classification (ADR 0015).
# Caller supplies a config-isolated, fully fetched main repository.
ss_fail() { echo "FAIL  session-search: $*" >&2; return 1; }
ss_hex() { case "$1" in *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" = "$2" ]; }
ss_manifest() {
  ss_manifest_pin='' ss_hosts='' ss_sums=''
  [ -f "$1" ] || return 0
  local kind a b extra
  while read -r kind a b extra || [ -n "$kind$a$b$extra" ]; do
    case "$kind" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] || { ss_fail 'extra manifest field'; return 1; }
    case "$kind" in
      pin)
        ss_hex "$a" 40 && [ -z "$b$ss_manifest_pin" ] || { ss_fail 'invalid/duplicate manifest pin'; return 1; }
        ss_manifest_pin=$a ;;
      host)
        case "$a" in ''|*[!a-zA-Z0-9_-]*) ss_fail 'invalid host'; return 1 ;; esac
        [ -z "$b" ] && ! printf '%s\n' "$ss_hosts" | grep -qxF "$a" || { ss_fail 'invalid/duplicate host'; return 1; }
        ss_hosts="${ss_hosts}${ss_hosts:+
}$a" ;;
      sha256)
        ss_hex "$a" 64 || { ss_fail 'invalid sha256'; return 1; }
        case "$b" in x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu|aarch64-apple-darwin) ;; *) ss_fail 'invalid target'; return 1 ;; esac
        ! printf '%s\n' "$ss_sums" | grep -q " $b$" || { ss_fail 'duplicate target'; return 1; }
        ss_sums="${ss_sums}${ss_sums:+
}$a $b" ;;
      *) ss_fail 'unknown manifest record'; return 1 ;;
    esac
  done < "$1"
  [ -n "$ss_manifest_pin" ] || { ss_fail 'manifest needs one pin'; return 1; }
}
ss_era() {
  local co=$1 pin=$2 manifest=$3 boundary
  ss_hex "$pin" 40 || { ss_fail 'not a 40-hex SHA'; return 1; }
  git -C "$co" merge-base --is-ancestor "$pin" refs/remotes/origin/main 2>/dev/null || { ss_fail "pin $pin is not an ancestor of main"; return 1; }
  ss_manifest "$manifest" || return 1
  [ -z "$ss_hosts" ] || [ "$ss_manifest_pin" = "$pin" ] || { ss_fail 'host manifest pin mismatch'; return 1; }
  boundary=$(git -C "$co" log --reverse --full-history --diff-filter=A --format=%H refs/remotes/origin/main -- crates/ccs/Cargo.toml) || { ss_fail 'cannot read Rust boundary history'; return 1; }
  boundary=${boundary%%$'\n'*}
  ss_pin_era=rust
  if [ -z "$ss_hosts" ]; then
    if [ -z "$boundary" ] || { [ "$pin" != "$boundary" ] && git -C "$co" merge-base --is-ancestor "$pin" "$boundary"; }; then ss_pin_era=python; fi
  fi
  echo "ERA $ss_pin_era boundary=${boundary:-none}"
}
ss_python_tree() {
  local co=$1 pin=$2 server=$3 tree f want
  tree=$(git -C "$co" ls-tree -r --name-only "$pin") || return 1
  ! printf '%s\n' "$tree" | grep -q '^crates/' || { ss_fail 'Python-era pin contains crates/'; return 1; }
  printf '%s\n' "$tree" | grep -qx 'ccs/cli.py' || { ss_fail 'no ccs/cli.py'; return 1; }
  ! printf '%s\n' "$tree" | grep -q '^ccs/.*/' || { ss_fail 'ccs/ is not flat'; return 1; }
  for f in session_redact.py session_codex.py; do
    want=$(git -C "$co" rev-parse "$pin:vendor/memory-mcp/$f") || return 1
    [ -f "$server/$f" ] && [ "$want" = "$(git hash-object --no-filters "$server/$f")" ] || { ss_fail "vendored $f differs from server"; return 1; }
  done
  echo 'PASS Python-era deployable tree and server identity'
}
