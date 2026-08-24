#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook (soft reminder, non-blocking), two independent checks:
#
# 1. A turn that ends after a background launch (`Task`, `Workflow`, or a Bash
#    call with `run_in_background: true`) without ever observing it — no
#    Monitor / ScheduleWakeup / TaskList-class call and no progress line since
#    the launch.
# 2. A turn that ends after a teammate's idle notification arrived with NO
#    delivered findings from that teammate and NO resend request sent since —
#    the "teammate went idle silently" shape of rules/sub-agents.md
#    "Agent-Team Messaging Contract".
#
# Both are mechanical backstops for prose that already existed when the
# violation kept recurring: check 1 for rules/sub-agents.md "Background Agent
# Progress Tracking" (the user had to ask "is the agent alive?" in 5 separate
# sessions over 30 days, 2026-07-28〜08-05); check 2 for the Messaging
# Contract's resend discipline (documented since 2026-06/07, yet two teammates
# in one 2026-08-23 session again idled without delivering and each needed a
# manually-noticed resend request). Prose needs a trigger at the exact moment
# of the violation — the turn ending.
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

reminders = []

# --- check 1: did anything observe the launch since? -------------------------

unless launch_index.nil?
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

  unless observed || completed
    reminders << ("REMINDER: this turn ends after a #{launch_label} launch with no " \
      "observation since — no Monitor / ScheduleWakeup / TaskList-class call " \
      "and no progress line. Per rules/sub-agents.md \"Background Agent " \
      "Progress Tracking\", a launch and its observation loop are one unit: " \
      "state the expected duration and establish the loop in the same turn, " \
      "or emit a concrete progress line (done N/M, last-activity time).")
  end
end

# --- check 2: teammate idle with no delivered findings and no resend ----------
# A teammate's findings arrive ONLY as a substantive <teammate-message …> (its
# plain-text output never reaches this session), and an idle notification is a
# JSON {"type":"idle_notification"} inside the same tag. A teammate that has
# gone idle while the transcript holds NO substantive message from it, and no
# SendMessage to it after the idle, delivered nothing — the recovery is a short
# resend request (never the full task prompt). Observed twice in one session
# (2026-08-23) two months after the prose rule landed.

TEAMMATE_CHUNK_RE = /\A<teammate-message[^>]*\bteammate_id="([^"]+)"/

def user_texts(entry)
  content = entry.dig("message", "content")
  case content
  when String then [content]
  when Array
    content.filter_map { |b| b["text"].to_s if b.is_a?(Hash) && b["type"] == "text" }
  else
    []
  end
end

idle_at = {}
delivered = {}
nudged_at = {}

entries.each_with_index do |entry, idx|
  case entry["type"]
  when "user"
    user_texts(entry).each do |text|
      next unless text.include?("<teammate-message")

      text.split(/(?=<teammate-message )/).each do |chunk|
        m = chunk.match(TEAMMATE_CHUNK_RE)
        next unless m

        tid = m[1]
        if chunk.include?("idle_notification")
          idle_at[tid] = idx
        else
          delivered[tid] = idx
        end
      end
    end
  when "assistant"
    tool_uses(entry).each do |block|
      next unless block["name"].to_s == "SendMessage"

      to = block.dig("input", "to").to_s
      nudged_at[to] = idx unless to.empty?
    end
  end
end

silent = idle_at.keys.select do |tid|
  delivered[tid].nil? && (nudged_at[tid] || -1) < idle_at[tid]
end

unless silent.empty?
  reminders << ("REMINDER: teammate #{silent.sort.join(", ")} went idle without " \
    "delivering findings via SendMessage, and no resend request was sent since " \
    "the idle notice. Per rules/sub-agents.md \"Agent-Team Messaging Contract\", " \
    "a teammate's plain-text output never reaches this session — send a short " \
    "resend request (never the full task prompt) before closing the turn.")
end

exit 0 if reminders.empty?

puts reminders.join("\n\n")
