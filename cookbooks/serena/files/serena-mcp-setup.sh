#!/bin/bash
# Helper script for Serena MCP initial setup and project switching
# Note: Once configured, use Serena's switch_modes tool for mode changes

MODE=${1:-onboarding}
CONTEXT=${2:-ide-assistant-enhanced}
PROJECT=${3:-$(pwd)}

echo "Setting up Serena MCP for project: $PROJECT"
echo "Initial mode: $MODE, Context: $CONTEXT"

# Remove existing Serena MCP configuration
claude mcp remove serena 2>/dev/null || true

# Add new configuration with specified mode
claude mcp add serena -- uvx --from git+https://github.com/oraios/serena serena-mcp-server --context "$CONTEXT" --mode "$MODE" --project "$PROJECT"

echo ""
echo "✅ Serena MCP configured successfully!"
echo ""
echo "📝 Mode switching:"
echo "   Once in Claude Code, use the switch_modes tool to change modes dynamically."
echo "   No need to restart the MCP server!"
echo ""
echo "🔧 Available contexts: ide-assistant-enhanced, desktop-app-enhanced"
echo "📂 Project: $PROJECT"
