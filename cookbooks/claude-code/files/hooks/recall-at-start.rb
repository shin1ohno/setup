#!/usr/bin/env ruby
# frozen_string_literal: true

# SessionStart hook: inject one short paragraph telling Claude to load the
# memory recall tool (deferred, so it needs ToolSearch) and recall once before
# the first reply. Origin: SH1-230 measured that Claude sessions subject to the
# "recall at conversation start" rule mostly did not recall it; SH1-242 / SH1-229
# stage 1 moves the instruction from the long CLAUDE.md to the session start.
#
# Gate: ~/.claude/recall-at-start.json (override: RECALL_AT_START_CONFIG),
#   {"enabled": true, "tool": "mcp__claude_ai_memory__recall"}
# placed by the memory-mirror cookbook on the personal hosts only. A missing,
# unreadable, malformed or disabled config, or a tool name that is not an MCP
# tool name, means silent exit 0 — hosts without the config (work Macs) get
# nothing. The hook only reads that one file: no network call, no credential,
# no subprocess. Sub-agents are not covered (no SubagentStart registration).
# Never raises and never exits non-zero: a hook failure must not disturb the
# session.
#
# The M3 marker for the SH1-230 re-measurement is the paragraph's first words,
# "Memory recall at session start:".

require "json"

CONFIG_PATH = ENV["RECALL_AT_START_CONFIG"] || File.join(Dir.home, ".claude", "recall-at-start.json")
TOOL_NAME   = /\Amcp__[A-Za-z0-9_-]{1,100}\z/

def load_tool
  config = JSON.parse(File.read(CONFIG_PATH))
  return nil unless config.is_a?(Hash) && config["enabled"] == true

  tool = config["tool"]
  tool.is_a?(String) && tool.match?(TOOL_NAME) ? tool : nil
rescue StandardError
  nil
end

def message(tool)
  "Memory recall at session start: the personal memory store's search tool is #{tool}. " \
    "It is deferred, so its schema loads with ToolSearch query \"select:#{tool}\". " \
    "The session rules ask for one recall on the task's key terms before the first reply. " \
    "Task instructions that forbid memory tools, or that ask only for a fixed reply, take precedence."
end

begin
  tool = load_tool
  if tool
    puts JSON.generate(
      "hookSpecificOutput" => {
        "hookEventName"     => "SessionStart",
        "additionalContext" => message(tool),
      },
    )
  end
rescue StandardError
  nil
end
exit 0
