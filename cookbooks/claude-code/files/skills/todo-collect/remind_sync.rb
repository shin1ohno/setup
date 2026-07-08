#!/usr/bin/env ruby
# frozen_string_literal: true
#
# remind_sync.rb — deterministic Apple Reminders <-> memory-store TODO sync.
#
# Stateless: every action is derived from two dumps — `remind --dump` JSON per
# target list, and a memory-dump JSON of OPEN todos. No state file. Link
# mechanism:
#   - reminder side: trailing notes token "[ai-todo:<memory-id>]"
#   - memory side:   "reminders:<externalId>" provenance inside content
#
# Sync rules (R = all reminders of target lists incl. completed, M = open memory todos):
#   1. capture_candidate: r in capture lists, !completed, no token, no m refs r,
#                     and due within the capture horizon (default 14 days —
#                     far-future scheduled reminders stay in Reminders, which
#                     already owns their notification; config
#                     capture.due_horizon_days, negative disables the filter)
#   2. annotate:      no token, some open m refs r (by externalId or id)
#                     -> append "[ai-todo:<m.id>]" to notes (convergence step)
#   3. create_mirror: m open, refs(m) empty (not reminder-derived), no r has
#                     token == m.id -> add to the mirror list. Only stores
#                     listed under mirror.stores are mirrored (egress guard)
#   4. forget (close A):   r completed and linked m open -> memory_action forget
#   5. complete (close B): r open, token set, token not in M -> complete reminder
#                     (complete_captured=false restricts rule 5 to mirror-list
#                     reminders — capture-origin reminders are left alone)
# Applying the plan repeatedly reaches a fixpoint within 2 applies; the next
# plan is empty for every rule (idempotent).
#
# CLI:
#   ruby remind_sync.rb --config CONFIG.json --memory-dump MEM.json \
#                       [--apply] [--remind-bin PATH]
#
# stdout: {"reminder_actions":[...],"memory_actions":[...],
#          "capture_candidates":[...],"counts":{...}} (single-line JSON)
#
# With --apply only reminder_actions are executed (via the remind CLI, in
# mklist -> add -> annotate -> complete order). memory_actions and
# capture_candidates are ALWAYS returned as JSON only — the calling skill
# performs them over MCP.

require "json"
require "optparse"
require "open3"
require "time"

module RemindSync
  # Last [ai-todo:X] match in the notes wins.
  TOKEN_RE = /\[ai-todo:([A-Za-z0-9_-]+)\]/
  # reminders:<externalId> provenance refs inside memory content.
  REF_RE = /reminders:([A-Za-z0-9:_.-]+)/
  # --due is attached only when the content carries an explicit 期日.
  DUE_RE = /期日[:：]\s*(\d{4}-\d{2}-\d{2})( \d{2}:\d{2})?/
  # Leading "TODO: " / "TODO (work): " style prefixes stripped from titles.
  TITLE_PREFIX_RE = /\ATODO(?:\s*\([^)]*\))?[:：]\s*/
  URL_RE = %r{https?://[^\s)>\]]+}
  COMPLETION_LINE_RE = /完了条件[:：][^\n]*/
  TITLE_MAX = 100
  # Rule-1 capture horizon: reminders due further out than this stay in
  # Reminders (which owns their notification) instead of becoming memory todos.
  DUE_HORIZON_DEFAULT_DAYS = 14
  OP_ORDER = { "mklist" => 0, "add" => 1, "annotate" => 2, "complete" => 3 }.freeze

  module_function

  def token_of(reminder)
    matches = reminder["notes"].to_s.scan(TOKEN_RE)
    matches.empty? ? nil : matches.last[0]
  end

  def refs_of(memory_item)
    memory_item["content"].to_s.scan(REF_RE).map { |m| m[0] }
  end

  # Title: strip the TODO prefix, take the first sentence (up to the first
  # 「。」or newline; whole content when neither exists), truncate to 100 chars.
  def mirror_title(content)
    body = content.to_s.sub(TITLE_PREFIX_RE, "")
    sentence = body.split(/。|\n/, 2).first.to_s
    sentence.strip[0, TITLE_MAX]
  end

  # Mirror notes per store policy. The token line is always the FINAL line.
  #   full:       completion-condition line + first URL + token line
  #   title-link: first URL + token line (body never leaves for iCloud)
  def mirror_notes(content, memory_id, policy)
    content = content.to_s
    parts = []
    if policy == "full"
      completion = content[COMPLETION_LINE_RE]
      parts << completion if completion
    end
    url = content[URL_RE]
    parts << url if url
    parts << "[ai-todo:#{memory_id}]"
    parts.join("\n")
  end

  def mirror_due(content)
    m = DUE_RE.match(content.to_s)
    return nil unless m

    "#{m[1]}#{m[2]}"
  end

  # Pure planner: (reminders, memory_items, config) -> plan hash. Zero side
  # effects; iteration follows input order so the plan is deterministic.
  class SyncPlanner
    def self.plan(reminders:, memory_items:, config:, now: Time.now)
      new(reminders, memory_items, config, now).plan
    end

    def initialize(reminders, memory_items, config, now = Time.now)
      @reminders = reminders
      @memory_items = memory_items
      @config = config
      @now = now
    end

    def plan
      open_ids = @memory_items.map { |m| m["id"] }
      refs_by_item = @memory_items.map { |m| [m, RemindSync.refs_of(m)] }
      tokens_in_use = @reminders.filter_map { |r| RemindSync.token_of(r) }

      annotates = []
      completes = []
      memory_actions = []
      capture_candidates = []

      @reminders.each do |r|
        tok = RemindSync.token_of(r)
        if tok.nil?
          ref_m = refs_by_item.find { |_m, ids| ids.include?(r["externalId"]) || ids.include?(r["id"]) }&.first
          if ref_m
            # Rule 2: converge a captured reminder onto its memory item.
            annotates << { "op" => "annotate", "id" => r["id"], "notes" => "[ai-todo:#{ref_m["id"]}]" }
          elsif !r["completed"] && capture_lists.include?(r["list"]) && within_capture_horizon?(r)
            # Rule 1: unlinked, unreferenced, open reminder in a capture list,
            # due now-ish (far-future scheduled reminders stay in Reminders).
            capture_candidates << candidate(r)
          end
          # Completed + unlinked + unreferenced -> ignored (neither rule 1 nor 4).
        elsif open_ids.include?(tok)
          if r["completed"]
            # Rule 4 (close A): reminder completion is mechanical evidence.
            m = @memory_items.find { |mm| mm["id"] == tok }
            memory_actions << { "op" => "forget", "store" => m["store"], "id" => m["id"],
                                "reason" => "linked reminder completed (#{r["id"]})" }
          end
          # Open + linked + m open -> in sync, nothing to do.
        elsif !r["completed"] && (r["list"] == mirror_list || complete_captured?)
          # Rule 5 (close B): linked memory item is gone -> complete reminder.
          completes << { "op" => "complete", "id" => r["id"] }
        end
      end

      memory_actions.uniq! { |a| [a["store"], a["id"]] }

      # Rule 3: mirror open, non-reminder-derived items of mirrored stores only.
      adds = []
      @memory_items.each do |m|
        policy = mirror_policies[m["store"]]
        next unless policy # egress guard: store not opted into mirroring
        next unless RemindSync.refs_of(m).empty?
        next if tokens_in_use.include?(m["id"])

        adds << add_action(m, policy)
      end

      reminder_actions = []
      # remind --mklist is idempotent, so it is emitted unconditionally at the
      # head of the plan whenever any mirror add is planned.
      reminder_actions << { "op" => "mklist", "list" => mirror_list } unless adds.empty?
      reminder_actions.concat(adds, annotates, completes)

      {
        "reminder_actions" => reminder_actions,
        "memory_actions" => memory_actions,
        "capture_candidates" => capture_candidates,
        "counts" => {
          "mklist" => adds.empty? ? 0 : 1,
          "add" => adds.size,
          "annotate" => annotates.size,
          "complete" => completes.size,
          "forget" => memory_actions.size,
          "capture_candidates" => capture_candidates.size
        }
      }
    end

    def mirror_list
      @config.dig("mirror", "list") || "Claude"
    end

    def capture_lists
      ((@config.dig("capture", "lists") || []) | [mirror_list])
    end

    private

    def mirror_policies
      @mirror_policies ||= (@config.dig("mirror", "stores") || []).each_with_object({}) do |s, h|
        h[s["name"]] = s["policy"] || "full"
      end
    end

    def complete_captured?
      v = @config.dig("mirror", "complete_captured")
      v.nil? ? true : v
    end

    # Rule-1 horizon: candidates whose due lies beyond now + N days are left to
    # Reminders (it owns their notification). No due -> always in horizon.
    # Negative N disables the filter. Unparseable due -> treated as in horizon.
    def within_capture_horizon?(r)
      days = @config.dig("capture", "due_horizon_days") || RemindSync::DUE_HORIZON_DEFAULT_DAYS
      return true if days.negative?
      return true unless r["due"]

      due = begin
        Time.iso8601(r["due"])
      rescue ArgumentError
        return true
      end
      due <= @now + (days * 86_400)
    end

    def candidate(r)
      { "id" => r["id"], "externalId" => r["externalId"], "title" => r["title"],
        "notes" => r["notes"], "due" => r["due"], "list" => r["list"] }
    end

    def add_action(m, policy)
      content = m["content"].to_s
      action = { "op" => "add", "list" => mirror_list,
                 "title" => RemindSync.mirror_title(content),
                 "notes" => RemindSync.mirror_notes(content, m["id"], policy) }
      due = RemindSync.mirror_due(content)
      action["due"] = due if due
      action
    end
  end

  # Thin wrapper around the remind CLI. The runner is injectable so tests run
  # without the remind binary (and therefore on Linux CI).
  class ReminderStore
    DEFAULT_BIN = File.join(Dir.home, ".local", "bin", "remind")

    attr_reader :bin

    # runner: callable(argv_array) -> [combined_output_string, exit_code]
    def initialize(bin: nil, runner: nil)
      @bin = bin || ENV["REMIND_BIN"] || DEFAULT_BIN
      @runner = runner || lambda { |argv|
        out, status = Open3.capture2e(*argv)
        [out, status.exitstatus]
      }
    end

    def dump(list:, include_completed: true)
      argv = [@bin, "--dump", "--list", list]
      argv << "--include-completed" if include_completed
      out, code = @runner.call(argv)
      raise "remind --dump failed for list #{list.inspect} (exit #{code}): #{out}" unless code.zero?

      JSON.parse(out)
    end

    # Returns [ok, argv, output].
    def execute(action)
      argv = argv_for(action)
      out, code = @runner.call(argv)
      [code.zero?, argv, out]
    end

    def argv_for(action)
      case action["op"]
      when "mklist"
        [@bin, "--mklist", action["list"]]
      when "add"
        argv = [@bin, action["title"], "--list", action["list"], "--notes", action["notes"]]
        argv += ["--due", action["due"]] if action["due"] && !action["due"].to_s.empty?
        argv
      when "annotate"
        [@bin, "--annotate", action["id"], "--notes", action["notes"]]
      when "complete"
        [@bin, "--complete", action["id"]]
      else
        raise ArgumentError, "unknown reminder action op: #{action["op"].inspect}"
      end
    end
  end

  module_function

  # Executes reminder_actions in mklist -> add -> annotate -> complete order
  # (stable within each op). Continues past failures so partial application is
  # reflected in counts by the caller. Returns [applied_count, failures].
  def apply_actions(actions, store, stderr: $stderr)
    applied = 0
    failures = []
    ordered = actions.sort_by.with_index { |a, i| [OP_ORDER.fetch(a["op"], 99), i] }
    ordered.each do |action|
      ok, argv, out = store.execute(action)
      if ok
        applied += 1
      else
        failures << { "action" => action, "output" => out }
        stderr.puts "remind_sync: FAILED #{argv.inspect}: #{out}"
      end
    end
    [applied, failures]
  end

  def main(argv)
    opts = { apply: false }
    parser = OptionParser.new do |o|
      o.banner = "Usage: ruby remind_sync.rb --config CONFIG.json --memory-dump MEM.json " \
                 "[--apply] [--remind-bin PATH]"
      o.on("--config PATH", "sync config JSON") { |v| opts[:config] = v }
      o.on("--memory-dump PATH", "open memory todos JSON array") { |v| opts[:memory_dump] = v }
      o.on("--apply", "execute reminder_actions via the remind CLI") { opts[:apply] = true }
      o.on("--remind-bin PATH", "remind CLI path (default: $REMIND_BIN or ~/.local/bin/remind)") do |v|
        opts[:remind_bin] = v
      end
    end
    parser.parse!(argv)

    unless opts[:config] && opts[:memory_dump]
      warn parser.banner
      return 2
    end

    config = JSON.parse(File.read(opts[:config]))
    memory_items = JSON.parse(File.read(opts[:memory_dump]))
    store = ReminderStore.new(bin: opts[:remind_bin])

    mirror_list = config.dig("mirror", "list") || "Claude"
    target_lists = ((config.dig("capture", "lists") || []) | [mirror_list])
    reminders = target_lists.flat_map { |l| store.dump(list: l, include_completed: true) }

    plan = SyncPlanner.plan(reminders: reminders, memory_items: memory_items, config: config)

    exit_code = 0
    if opts[:apply]
      applied, failures = apply_actions(plan["reminder_actions"], store)
      plan["counts"]["applied"] = applied
      plan["counts"]["apply_failed"] = failures.size
      exit_code = 1 unless failures.empty?
    end

    $stdout.puts JSON.generate(plan)
    exit_code
  rescue StandardError => e
    warn "remind_sync: #{e.message}"
    1
  end
end

exit RemindSync.main(ARGV) if __FILE__ == $PROGRAM_NAME
