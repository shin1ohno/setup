#!/usr/bin/env ruby
# frozen_string_literal: true

# SessionStart (compact) hook: remind critical rules after compaction
# Outputs a message that gets injected into the conversation context

puts <<~MSG
  REMINDER after compaction — critical rules still apply:
  1. AskUserQuestion: every ambiguity, every analysis must end with a question
  2. Communicate in Japanese
  3. Preserve: current plan state, modified file paths, test commands, AskUserQuestion decisions
  4. CLAUDE.md source of truth: cookbooks/claude-code/files/CLAUDE.md
MSG
