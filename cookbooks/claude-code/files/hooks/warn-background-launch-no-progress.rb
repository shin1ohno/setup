#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook (soft reminder, non-blocking): detect a turn that ends after a
# background launch (`Task`, `Workflow`, or a Bash call with
# `run_in_background: true`) without ever observing it — no Monitor /
# ScheduleWakeup / TaskList-class call and no progress line since the launch.
#
# This is the mechanical backstop for rules/sub-agents.md "Background Agent
# Progress Tracking": that section was already written in full when the user
# had to ask "is the agent alive?" in 5 separate sessions over 30 days
# (2026-07-28〜08-05), so the prose needs a trigger at the exact moment of the
# violation — the turn ending.
#
# Non-blocking on purpose (same reasoning as detect-prose-menu.rb): a
# deliberately-parked long job must still be able to end its turn. The hook
# reminds; it never traps the session.
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

# --- classification tables ---------------------------------------------------

# Tools whose invocation STARTS work that outlives the turn.
LAUNCH_TOOLS = %w[Task Workflow].freeze

# Tools whose invocation counts as OBSERVING that work.
OBSERVE_TOOLS = %w[
  Monitor ScheduleWakeup TaskList TaskGet TaskOutput TaskStop BashOutput
].freeze

# Bash commands that read an observation source directly.
OBSERVE_BASH_RE = /journal\.jsonl|TaskList|gh\s+(?:pr\s+checks|run\s+(?:watch|list))|\.claude\/projects\/.*\.jsonl/

# A progress line in assistant TEXT: "done 3/8", "3/8 完了", "8 本中 3 本",
# "last activity", "最終活動", or an explicit stream-completion note.
PROGRESS_TEXT_RE = %r{
  \b\d+\s*/\s*\d+\b            | # 3/8, done 3 / 8
  \d+\s*件\s*(?:完了|終了)      | # 3 件完了
  \d+\s*本\s*(?:完了|終了)      | # 3 本完了
  最終活動 | 直近完了 | last[- ]activity | still\s+running | 進捗
}xi

def tool_uses(entry)
  content = entry.dig("message", "content")
  return [] unless content.is_a?(Array)

  content.select { |b| b.is_a?(Hash) && b["type"] == "tool_use" }
end

def text_of(entry)
  content = entry.dig("message", "content")
  return "" unless content.is_a?(Array)

  content.filter_map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.join("\n")
end

# --- walk the transcript -----------------------------------------------------

entries = []
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
    entries << entry if entry.is_a?(Hash)
  end
rescue StandardError
  exit 0
end

exit 0 if entries.empty?

# The last assistant message must be tool_use-free text: if the turn ended on a
# tool call we are not at a "closing the turn with prose" moment.
last_assistant = entries.reverse.find { |e| e["type"] == "assistant" }
exit 0 if last_assistant.nil?
exit 0 unless tool_uses(last_assistant).empty?

# Find the most recent launch, and remember its tool_use ids.
launch_index = nil
launch_ids = []
launch_label = nil

entries.each_with_index do |entry, idx|
  next unless entry["type"] == "assistant"

  tool_uses(entry).each do |block|
    name = block["name"].to_s
    backgrounded = block.dig("input", "run_in_background") == true
    next unless LAUNCH_TOOLS.include?(name) || (name == "Bash" && backgrounded)

    launch_index = idx
    launch_ids = [block["id"].to_s]
    launch_label = name
  end
end

exit 0 if launch_index.nil?

# --- did anything observe it since? -----------------------------------------

observed = false
completed = false

entries.each_with_index do |entry, idx|
  next if idx <= launch_index

  case entry["type"]
  when "assistant"
    tool_uses(entry).each do |block|
      name = block["name"].to_s
      observed = true if OBSERVE_TOOLS.include?(name)
      if name == "Bash"
        cmd = block.dig("input", "command").to_s
        observed = true if cmd =~ OBSERVE_BASH_RE
      end
    end
    observed = true if text_of(entry) =~ PROGRESS_TEXT_RE
  when "user"
    # A task-notification, or the launch's own tool_result, means the work
    # already reported back — nothing left to observe.
    content = entry.dig("message", "content")
    if content.is_a?(Array)
      content.each do |block|
        next unless block.is_a?(Hash)

        completed = true if block["type"] == "tool_result" && launch_ids.include?(block["tool_use_id"].to_s)
        if block["type"] == "text" && block["text"].to_s.include?("task-notification")
          completed = true
        end
      end
    elsif content.is_a?(String) && content.include?("task-notification")
      completed = true
    end
  end
end

exit 0 if observed || completed

puts "REMINDER: this turn ends after a #{launch_label} launch with no " \
     "observation since — no Monitor / ScheduleWakeup / TaskList-class call " \
     "and no progress line. Per rules/sub-agents.md \"Background Agent " \
     "Progress Tracking\", a launch and its observation loop are one unit: " \
     "state the expected duration and establish the loop in the same turn, " \
     "or emit a concrete progress line (done N/M, last-activity time)."
