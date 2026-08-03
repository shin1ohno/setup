# frozen_string_literal: true
#
# mcp: the OS-independent prerequisite half — the tools both renders shell out
# to, plus the two npm-backed MCP binaries. Included FIRST by darwin.rb and
# linux.rb so resource order matches the pre-split default.rb exactly
# (nodejs/awscli/yq/jq → mise_tool → SSM gate → renders).

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Ensure AWS CLI is available for SSM parameter retrieval
include_platform_cookbook "awscli"

# Ensure yq is available for YAML processing
include_cookbook "yq"

# Ensure jq is available for JSON processing in generate_config.sh
include_cookbook "jq"

%w(mcp-hub mcp-remote).each do |com|
  mise_tool com do
    backend "npm"
  end
end
