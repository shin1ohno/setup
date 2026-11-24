# frozen_string_literal: true
#
# mcp: the Claude Code USER-scope render of files/servers.yml — the one render
# that runs on EVERY platform. Included from INSIDE the SSM auth gate of both
# darwin.rb and linux.rb (it resolves /mcp/* parameters itself), so the two
# per-OS recipes share one definition of this resource instead of drifting.
#
# Independent render of servers.yml into Claude Code USER scope — a third
# surface alongside Claude Desktop (darwin.rb) and Codex CLI (codex-cli
# cookbook). Mirrors the codex idiom: reads servers.yml directly + resolves SSM
# itself + renders native (`claude mcp add --transport` for http/sse, `add-json`
# for stdio) — NOT derived from the Desktop output. Idempotent; account-connector
# servers (no `desktop:` flag) are skipped (they are claude.ai connectors).

claude_path = "#{node[:setup][:home]}/.local/bin/claude"
register_script = File.join(File.dirname(__FILE__), "files", "register_claude_code.sh")
yaml_path = File.join(File.dirname(__FILE__), "files", "servers.yml")

execute "register MCP servers into Claude Code (user scope)" do
  # bash -c for `set -o pipefail`; export mise shims + /usr/local/bin so the
  # script finds yq/jq/node and the awscli pkg binary.
  #
  # PLATFORM is passed explicitly because the script defaults to darwin
  # (`CURRENT_PLATFORM="${PLATFORM:-darwin}"`, written when only macOS reached
  # it). Without it a Linux host would register every server pinned
  # `platforms: [darwin]` — e.g. obsidian-mcp-tools, whose command lives under
  # the macOS iCloud Drive path and cannot exist here.
  command <<~CMD.strip
    bash -c '
      set -euo pipefail
      export PATH="#{node[:setup][:home]}/.local/share/mise/shims:/usr/local/bin:$PATH"
      PLATFORM=#{platform_value(darwin: "darwin", linux: "linux")} bash #{register_script} #{yaml_path}
    '
  CMD
  user node[:setup][:user]
  only_if "test -x #{claude_path}"
end
