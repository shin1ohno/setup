# Serena MCP project setup helpers
alias serena-setup='serena-mcp-setup'
alias serena-setup-ide='serena-mcp-setup onboarding ide-assistant-enhanced'
alias serena-setup-desktop='serena-mcp-setup onboarding desktop-app-enhanced'

# Quick start for common scenarios
alias serena-new='serena-mcp-setup onboarding ide-assistant-enhanced'
alias serena-continue='serena-mcp-setup no-onboarding ide-assistant-enhanced'

# Help command
serena-help() {
  echo "🚀 Serena MCP Commands:"
  echo ""
  echo "  serena-new        - Start a new project (onboarding mode)"
  echo "  serena-continue   - Continue existing project (no-onboarding mode)"
  echo "  serena-setup      - Custom setup: serena-setup [mode] [context] [project-path]"
  echo ""
  echo "📝 Mode switching in Claude Code:"
  echo "  Use the switch_modes tool to change between:"
  echo "  - onboarding, planning, editing, interactive, no-onboarding"
  echo ""
  echo "🔧 Contexts:"
  echo "  - ide-assistant-enhanced (Claude Code optimized)"
  echo "  - desktop-app-enhanced (Full features)"
}
