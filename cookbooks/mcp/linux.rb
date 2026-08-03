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

# The render resolves /mcp/* SSM parameters, so gate on them. Block here until
# AWS auth is in place — interactive pause + re-check loop; a non-TTY host
# (fleet apply, CI) warns and skips instead. darwin.rb declares the same gate
# around a body that also generates the Desktop config; keep the two argument
# lists in sync.
require_external_auth(
  tool_name: "AWS CLI (for MCP server SSM params)",
  # Probe the ACTUAL SSM path the generators read (/mcp/obsidian-api-key) so the
  # gate fails when this identity lacks SSM access. `aws sts get-caller-identity`
  # was a false gate — it passes for any valid identity regardless of SSM scope.
  check_command: "aws ssm get-parameter --name /mcp/obsidian-api-key --with-decryption --query Parameter.Value --output text --region ${AWS_REGION:-ap-northeast-1} >/dev/null 2>&1",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
) do
  include_recipe "register"
end

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
