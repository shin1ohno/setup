# frozen_string_literal: true

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Ensure AWS CLI is available for SSM parameter retrieval
include_cookbook "awscli"

# Ensure yq is available for YAML processing
include_cookbook "yq"

# Ensure jq is available for JSON processing in generate_config.sh
include_cookbook "jq"

%w(mcp-hub mcp-remote).each do |com|
  mise_tool com do
    backend "npm"
  end
end

# =============================================================================
# Render servers.yml into the MCP surfaces
# =============================================================================
# Two independent renders of the same source:
#
#   - Claude Desktop's claude_desktop_config.json — macOS only. The app has no
#     Linux build, and generate_config.sh hardcodes current_platform="darwin"
#     for that reason.
#   - Claude Code USER scope — EVERY platform. Bare-metal pro, the dev LXCs and
#     the sh1-cloud GCE box run the same Claude Code CLI and need the same
#     servers, but this whole section used to sit inside the darwin check, so
#     those hosts ended up with no locally-configured MCP server at all. The
#     gate and the registrar therefore live at top level now; only the Desktop
#     resources stay behind `if darwin`.
darwin = node[:platform] == "darwin"

yaml_path = File.join(File.dirname(__FILE__), "files", "servers.yml")

if darwin
  claude_desktop_config_dir = "#{node[:setup][:home]}/Library/Application Support/Claude"

  directory claude_desktop_config_dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end

  # Create generated directory for temporary files
  generated_dir = "#{node[:setup][:root]}/generated"
  directory generated_dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end

  generator_script = File.join(File.dirname(__FILE__), "files", "generate_config.sh")
  temp_path = "#{generated_dir}/claude_desktop_config.json"
  output_path = "#{claude_desktop_config_dir}/claude_desktop_config.json"
end

# Both renders resolve /mcp/* SSM parameters, so one gate covers them. Block
# here until AWS auth is in place — interactive pause + re-check loop; a
# non-TTY host (fleet apply, CI) warns and skips instead.
require_external_auth(
  tool_name: "AWS CLI (for MCP server SSM params)",
  # Probe the ACTUAL SSM path the generators read (/mcp/obsidian-api-key) so the
  # gate fails when this identity lacks SSM access. `aws sts get-caller-identity`
  # was a false gate — it passes for any valid identity regardless of SSM scope.
  check_command: "aws ssm get-parameter --name /mcp/obsidian-api-key --with-decryption --query Parameter.Value --output text --region ${AWS_REGION:-ap-northeast-1} >/dev/null 2>&1",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
) do
  if darwin
    # Generate config to temporary location in setup root
    execute "generate claude_desktop_config.json" do
      command "bash #{generator_script} #{yaml_path} #{temp_path}"
      user node[:setup][:user]
    end
  end

  # Independent render of servers.yml into Claude Code USER scope — a third
  # surface alongside Claude Desktop (above) and Codex CLI (codex-cli cookbook).
  # Mirrors the codex idiom: reads servers.yml directly + resolves SSM itself +
  # renders native (`claude mcp add --transport` for http/sse, `add-json` for
  # stdio) — NOT derived from the Desktop output. Idempotent; account-connector
  # servers (no `desktop:` flag) are skipped (they are claude.ai connectors).
  claude_path = "#{node[:setup][:home]}/.local/bin/claude"
  register_script = File.join(File.dirname(__FILE__), "files", "register_claude_code.sh")
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
        PLATFORM=#{darwin ? "darwin" : "linux"} bash #{register_script} #{yaml_path}
      '
    CMD
    user node[:setup][:user]
    only_if "test -x #{claude_path}"
  end
end

if darwin
  # Merge managed config into existing file, preserving user-added mcpServers.
  # Runs in a local_ruby_block so the merge logic and only_if check both
  # evaluate at converge time, after the preceding execute has produced
  # temp_path. A bare Ruby `if File.exist?(temp_path)` at recipe-load time
  # ran before the execute and skipped declaring the merge on clean runs.
  local_ruby_block "merge claude_desktop_config.json" do
    block do
      managed  = JSON.parse(File.read(temp_path))
      existing = File.exist?(output_path) ? (JSON.parse(File.read(output_path)) rescue {}) : {}

      merged_servers = (existing["mcpServers"] || {}).merge(managed["mcpServers"] || {})
      merged = existing.merge(managed)
      merged["mcpServers"] = merged_servers

      File.open(output_path, "w") { |f| f.write(JSON.pretty_generate(merged) + "\n") }
      # 0o600: merged file holds plaintext MCP API keys (matches every other secret file in this repo).
      File.chmod(0o600, output_path)
      File.delete(temp_path)
    end
    only_if { File.exist?(temp_path) }
  end
end

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
