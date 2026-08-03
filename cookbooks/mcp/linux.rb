# frozen_string_literal: true
#
# mcp (Linux): the Claude Code USER-scope render only.
#
# Claude Desktop has no Linux build, so none of darwin.rb's
# claude_desktop_config.json resources exist here. Bare-metal pro, the dev LXCs
# and the sh1-cloud GCE box do run the same Claude Code CLI and need the same
# servers — that render lives in register.rb and is shared with darwin.rb.
#
# Prerequisites (nodejs/awscli/yq/jq + the npm MCP binaries) are in common.rb.

include_recipe "common"

# NO auth gate here, deliberately (2026-08 gap decision): the only `ssm:`
# entry in files/servers.yml belongs to obsidian-mcp-tools, which is pinned
# `platforms: [darwin]`, and register_claude_code.sh runs with PLATFORM=linux
# so it never touches that server — the Linux render resolves ZERO SSM
# parameters. The old gate here probed /mcp/obsidian-api-key anyway, which the
# fleet identity (pve-bootstrap-ssm) cannot read, so every LXC apply silently
# skipped the whole registration for a credential it never needed
# (gate-report surfaced this as mitamae_gate_attention on pro-dev).
# darwin.rb DOES keep its gate — the Desktop config + the darwin register
# really fetch the obsidian key there.
#
# CONTRACT: if a server reachable on Linux (no `platforms:` pin, or pinned
# [linux]) ever gains an `ssm:` field, reinstate a require_external_auth gate
# here probing that exact path.
include_recipe "register"

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
