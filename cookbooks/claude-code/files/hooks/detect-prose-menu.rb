#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook (soft reminder, non-blocking): detect when the final assistant
# message ended as tool_use-free TEXT that enumerates 2+ options AND then does
# one of: (a) ends in a question, (b) ends with an "I'll proceed once you
# decide" declaration over decision-point-looking options, or (c) lists 2+
# "…しますか？" choices even without a trailing question mark — i.e. a prose menu
# that should have been an AskUserQuestion. Emits a one-line reminder to stdout
# when matched.
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

  # Japanese questions terminated with a full stop instead of a question mark
  # ("どれか走らせますか。" / "TODO.md に積みますか。") — all three 2026-07
  # recurrences slipped through the ？-only check on this exact shape.
  return true if last_line =~ /(?:ますか|ましょうか|でしょうか)\s*[。.]?\s*\z/

  # Trailing whitespace/punctuation tolerance on the whole message.
  stripped = text.rstrip
  stripped.end_with?("?", "？")
end

# Variant (b): the message ENDS with an "I'll start once you decide" declaration
# ("決めれば着手します" / "デフォルトを採用して進めます") instead of a question mark.
# Enumerating decision points and then declaring you'll proceed is the same
# prose-menu violation dressed as a statement.
DECLARATION_RE =
  /(?:決めれば|決めたら|決まれば).{0,10}(?:着手|進め)|デフォルト(?:を|で)?採用.{0,20}(?:着手|進め|実行)|(?:てよければ|でよければ|よろしければ).{0,20}(?:実行|進め|マージ|merge|着手)/

# false-positive suppression for (b): only count it when the enumerated lines
# actually read as decision points.
DECISION_SIGNAL_RE = /しますか|どちら|選択|決め/

def declaration_ending?(text)
  tail = text.lines.map(&:strip).reject(&:empty?).last(2).join("\n")
  !(tail =~ DECLARATION_RE).nil?
end

def decision_point_signal?(text)
  !(text =~ DECISION_SIGNAL_RE).nil?
end

# Variant (c): 2+ of the enumerated lines themselves end in a question
# ("…しますか？"), even when the message body does not end in a question mark.
def question_option_lines?(text)
  count =
    text.lines.map(&:strip).count do |l|
      (l =~ /\A(?:[-*+]\s|\d+[.)]\s|(?:[A-Za-z]|案[A-Za-z0-9]|選択肢\s*\d+)[:.)、]\s)/) &&
        (l =~ /(?:しますか|ますか)\s*[?？。.]?\s*\z/)
    end
  count >= 2
end

begin
  fire =
    enumerates_options?(text) && (
      ends_in_question?(text) ||
      (declaration_ending?(text) && decision_point_signal?(text)) ||
      question_option_lines?(text)
    )
  exit 0 unless fire
rescue StandardError
  exit 0
end

puts "REMINDER: the final message reads as a prose menu — it enumerates 2+ " \
     "options/decision points and then asks a question, ends with an " \
     "\"I'll proceed once you decide\" declaration, or lists 2+ \"…しますか？\" " \
     "choices. Per the AskUserQuestion rule, present the choices via " \
     "AskUserQuestion instead of a prose list-and-ask/declare."
