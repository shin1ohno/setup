# frozen_string_literal: true

# herdr - agent multiplexer that lives in your terminal (tmux replacement)
# https://herdr.dev  https://github.com/ogulcancelik/herdr
#
# Upstream ships bare prebuilt binaries (no archive, no .sha256 sidecar) on
# each GitHub release: herdr-{macos,linux}-{aarch64,x86_64}. The official
# installer (`curl -fsSL https://herdr.dev/install.sh | sh`) downloads the
# matching asset to ~/.local/bin/herdr and chmod +x — no integrity check.
# We mirror that placement but pin the version + verify sha256 ourselves so
# the install is reproducible across the fleet.
#
# Homebrew has a formula (homebrew-core) but it lags (0.6.4 vs 0.6.6) and
# builds from source via cargo + zig. mise has no registry entry. Direct
# binary download is the only path that gives the current version on both
# macOS and Linux without a Rust toolchain.

# Local vars, not top-level constants: mitamae loads every recipe into one
# Ruby namespace, so a generic `VERSION` would collide across cookbooks.
herdr_version = "0.8.0"

# sha256 of each release binary at v#{herdr_version}. On version bump, recompute:
#   for t in macos-aarch64 macos-x86_64 linux-aarch64 linux-x86_64; do
#     curl -fsSL ".../v<ver>/herdr-$t" | shasum -a 256
#   done
# Nothing else is hand-maintained across a bump: the agent skill and the zsh
# completion below are generated from whichever binary this pin installs, and
# their guards compare content, so both refresh on the next apply.
checksums = {
  "macos-aarch64" => "d53a9f93fccfdfcc55632927bf51002f5add0aa7990bcdf508ffbd84ac658178",
  "macos-x86_64"  => "77cb5afd6c8fcaaaf3bc28e474ec01c209331ad08094e20d7f8aa9b0bb78d649",
  "linux-aarch64" => "f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87",
  "linux-x86_64"  => "b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28",
}

os = platform_value(darwin: "macos", linux: "linux")
arch = case node[:hw][:machine]
       when "arm64", "aarch64" then "aarch64"
       else "x86_64"
       end
target = "#{os}-#{arch}"
sha = checksums.fetch(target)
url = "https://github.com/ogulcancelik/herdr/releases/download/v#{herdr_version}/herdr-#{target}"

bin_dir = "#{node[:setup][:home]}/.local/bin"
herdr_path = "#{bin_dir}/herdr"

directory bin_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Download + verify + install in one pipeline. Re-runs only when the on-disk
# binary is missing or reports a different version (so a VERSION bump above
# re-downloads, while a matching install is a no-op).
execute "install herdr #{herdr_version} (#{target})" do
  user node[:setup][:user]
  # Wrap in `bash -c` because mitamae's execute runs via /bin/sh, which is
  # dash on Ubuntu and rejects `set -o pipefail` (same fix already used by
  # cookbooks/codex-cli and cookbooks/mcp -- confirmed live: the un-wrapped
  # form fails with "set: Illegal option -o pipefail" and, since mitamae has
  # no ignore_failure, aborts the whole recipe run).
  command <<~SH.strip
    bash -c '
      set -euo pipefail
      tmp="$(mktemp)"
      trap "rm -f $tmp" EXIT
      curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "#{url}" -o "$tmp"
      echo "#{sha}  $tmp" | shasum -a 256 -c -
      install -m 0755 "$tmp" "#{herdr_path}"
    '
  SH
  not_if "'#{herdr_path}' --version 2>/dev/null | grep -q '#{herdr_version}'"
end

# Managed config (converted from ~/.tmux.conf). Overwrites on content drift —
# the cookbook is the source of truth for herdr keybindings/theme.
directory "#{node[:setup][:home]}/.config/herdr" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

remote_file "#{node[:setup][:home]}/.config/herdr/config.toml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/config.toml"
end

# `hr` — fzf-powered session launcher, the herdr analog of `tm` (cookbooks/fzf
# `fzf-advanced`).
#   hr <name>  → create-or-attach the named session (`herdr --session <name>`)
#   hr         → fzf-pick an existing session and attach; fall back to the
#                default session (`herdr`).
# Corrected 2026-08-05 — the previous comment claimed this works "whether or not
# a client is already running" and that the fallback covers a "none exist" case.
# Neither holds: it is an OUTER-SHELL launcher, not a tmux `switch-client`.
# Nested launch is refused while experimental.allow_nested = false, so from
# inside a pane the user must detach (prefix+q) first. And `session list` always
# contains `default`, so the empty-list branch is dead — the `|| herdr` fallback
# actually fires on fzf cancel, list failure and attach failure alike, which
# masks real errors. Left as-is deliberately: tightening it changes the
# launcher's runtime behaviour and belongs in its own change.
# Named `hr` (not `hd`) because `hd` collides with util-linux's hexdump alias
# (/usr/bin/hd) on Linux.
# Names are parsed from the tabular `session list` (skip header), mirroring the
# no-json-parser style of `tm`.
#
# Remove the orphaned `hd` profile script left on machines that applied the
# pre-rename cookbook (PR #425). Without this, `50-herdr-hd.sh` lingers and
# keeps the old colliding `hd()` function defined alongside the new `hr()`.
["sh", "fish"].each do |ext|
  file "#{node[:setup][:root]}/profile.d/50-herdr-hd.#{ext}" do
    action :delete
  end
end

add_profile "herdr-hr" do
  bash_content <<~'EOS'
  hr() {
    if [ -n "$1" ]; then
      herdr --session "$1"
      return
    fi
    session=$(herdr session list 2>/dev/null | awk 'NR>1 {print $1}' | fzf --exit-0) \
      && herdr session attach "$session" || herdr
  }
  EOS
end

# Agent skill for Claude Code + Codex CLI. herdr ships its own instructions
# inside the binary (`herdr --skill` — 195 lines at 0.8.0, covering the CLI
# surface, the pane/agent lifecycle states, and the "never stop the server you
# did not start" safety rules), so generate from the pinned binary instead of
# vendoring a copy that silently rots at the next bump. files/skill-local.md
# appends what upstream cannot know: config.toml is a cookbook render target,
# `herdr update` fights the version pin, and `hr` is the session entry point.
# The skill self-gates on HERDR_ENV=1, so it stays inert outside a herdr pane.
skill_local = File.join(File.dirname(__FILE__), "files", "skill-local.md")
# One composition, used by both the install command and its guard. Emitting on
# stdout lets the guard be a plain `| cmp -s - <dst>` (no process substitution,
# so it works under mitamae's /bin/sh), and makes a herdr bump OR an edit to
# skill-local.md regenerate both copies on the next apply.
skill_body = %({ "#{herdr_path}" --skill; printf "\\n"; cat "#{skill_local}"; })

# Both agents read <name>/SKILL.md from their own skills dir and share the same
# YAML frontmatter shape, so one composed file serves both. Every entry recipe
# that includes roles/core (this cookbook) also includes roles/llm (claude-code,
# codex-cli) — darwin.rb, linux.rb, cookbooks/lxc-dev-workstation — so neither
# destination lands on a host without the agent that reads it. Codex discovers
# $CODEX_HOME/skills/<name> (its bundled set lives under skills/.system).
{
  ".claude/skills/herdr" => "Claude Code",
  ".codex/skills/herdr" => "Codex CLI",
}.each do |rel_dir, agent|
  skill_dir = "#{node[:setup][:home]}/#{rel_dir}"

  directory skill_dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  execute "install herdr agent skill for #{agent}" do
    user node[:setup][:user]
    # bash -c for `set -o pipefail` (dash rejects it), same as the install
    # above. Compose into a temp file and `install` it so a mid-pipeline
    # failure cannot leave a half-written SKILL.md in place.
    command <<~SH.strip
      bash -c '
        set -euo pipefail
        tmp="$(mktemp)"
        trap "rm -f $tmp" EXIT
        #{skill_body} > "$tmp"
        install -m 0644 "$tmp" "#{skill_dir}/SKILL.md"
      '
    SH
    not_if "bash -c '#{skill_body}' | cmp -s - #{skill_dir}/SKILL.md"
  end
end

# zsh completion. `herdr completion zsh` emits a clap script whose line 1 is
# `#compdef herdr`, so it autoloads from fpath with no sourcing hook.
# ~/.local/share/zsh/site-functions is put on fpath pre-compinit by
# cookbooks/dot-zsh, but its `directory` resource lives in cookbooks/mise
# (roles/programming, which runs AFTER roles/core) — declare it here so a fresh
# host converges in one pass.
zsh_comp_dir = "#{node[:setup][:home]}/.local/share/zsh/site-functions"
zsh_comp = "#{zsh_comp_dir}/_herdr"

directory zsh_comp_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "generate herdr zsh completion" do
  user node[:setup][:user]
  command <<~SH.strip
    bash -c '
      set -euo pipefail
      tmp="$(mktemp)"
      trap "rm -f $tmp" EXIT
      "#{herdr_path}" completion zsh > "$tmp"
      install -m 0644 "$tmp" "#{zsh_comp}"
    '
  SH
  # Content compare, not mise's `test -f`: the script enumerates subcommands,
  # so a version bump has to regenerate it rather than keep a stale copy.
  not_if "'#{herdr_path}' completion zsh | cmp -s - #{zsh_comp}"
end
