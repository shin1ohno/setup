#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook (soft reminder, non-blocking): detect when the final assistant
# message ended as tool_use-free TEXT that both (a) enumerates 2+ options and
# (b) ends in a question — i.e. a prose menu that should have been an
# AskUserQuestion. Emits a one-line reminder to stdout when matched.
#
# Never blocks and never raises: any failure -> print nothing, exit 0.

require "json"

# --- read + parse the Stop payload ------------------------------------------

payload =
  begin
    JSON.parse($stdin.read)
  rescue StandardError
    exit 0
  end

transcript_path = payload["transcript_path"].to_s
exit 0 if transcript_path.empty?

# --- find the LAST assistant message in the JSONL transcript ----------------

last_assistant = nil
begin
  File.foreach(transcript_path) do |line|
    line = line.strip
    next if line.empty?

    entry =
      begin
        JSON.parse(line)
      rescue StandardError
        next
      end

    last_assistant = entry if entry.is_a?(Hash) && entry["type"] == "assistant"
  end
rescue StandardError
  exit 0
end

exit 0 if last_assistant.nil?

# --- extract content blocks; bail if any tool_use is present ----------------

content = last_assistant.dig("message", "content")
content = [] unless content.is_a?(Array)

text_parts = []
content.each do |block|
  next unless block.is_a?(Hash)

  # If the final message issued a tool call (including AskUserQuestion), it is
  # not a prose menu — nothing to remind about.
  exit 0 if block["type"] == "tool_use"

  text_parts << block["text"].to_s if block["type"] == "text"
end

text = text_parts.join("\n").strip
exit 0 if text.empty?

# --- heuristic: enumerates 2+ options AND ends in a question ----------------

def enumerates_options?(text)
  lines = text.lines.map(&:strip)

  # Markdown bullets: "- ", "* ", "+ "
  bullets = lines.count { |l| l =~ /\A[-*+]\s+\S/ }
  return true if bullets >= 2

  # Numbered lists: "1. ", "2) ", etc.
  numbered = lines.count { |l| l =~ /\A\d+[.)]\s+\S/ }
  return true if numbered >= 2

  # Labelled choices anywhere: "A:", "B)", "1:", "案A", etc. at a line start.
  labelled = lines.count { |l| l =~ /\A(?:[A-Za-z]|\d+|案[A-Za-z0-9]|選択肢\s*\d+)[:.)、]\s*\S/ }
  return true if labelled >= 2

  false
end

def ends_in_question?(text)
  # Consider the tail of the message: last non-empty line, and the whole text
  # as a fallback (a trailing question sometimes wraps onto the final line).
  last_line = text.lines.map(&:strip).reject(&:empty?).last.to_s
  return true if last_line.end_with?("?", "？")

  # Trailing whitespace/punctuation tolerance on the whole message.
  stripped = text.rstrip
  stripped.end_with?("?", "？")
end

begin
  exit 0 unless enumerates_options?(text) && ends_in_question?(text)
rescue StandardError
  exit 0
end

puts "REMINDER: the final message reads as a prose menu (enumerated options " \
     "ending in a question). Per the AskUserQuestion rule, present choices via " \
     "AskUserQuestion instead of a prose list-and-ask."
