# frozen_string_literal: true
#
# Unit tests for remind_sync.rb. SyncPlanner (pure) is the primary target;
# ReminderStore / apply_actions run against an injected stub runner, so the
# suite has no dependency on the remind binary (runs on Linux CI).
#
# Run: ruby test_remind_sync.rb

require "minitest/autorun"
require "stringio"
require_relative "remind_sync"

module RemindSyncTestHelpers
  def reminder(id:, list:, title: "task", notes: "", completed: false, external_id: nil, due: nil)
    {
      "id" => id,
      "externalId" => external_id || "ext-#{id}",
      "title" => title,
      "notes" => notes,
      "list" => list,
      "completed" => completed,
      "completionDate" => completed ? "2026-07-07T12:00:00+09:00" : nil,
      "due" => due,
      "priority" => 0,
      "created" => "2026-07-01T00:00:00+09:00"
    }
  end

  def memory_item(id:, content:, store: "ai-memory")
    { "id" => id, "store" => store, "content" => content, "tags" => ["todo"] }
  end

  def config(mirror_list: "Claude", stores: [{ "name" => "ai-memory", "policy" => "full" }],
             complete_captured: true, capture_lists: ["Inbox"])
    {
      "mirror" => {
        "list" => mirror_list,
        "stores" => stores,
        "complete_captured" => complete_captured
      },
      "capture" => { "lists" => capture_lists, "sink" => "ai-memory" }
    }
  end

  def plan(reminders:, memory_items:, cfg: config, now: nil)
    kwargs = { reminders: reminders, memory_items: memory_items, config: cfg }
    kwargs[:now] = now if now
    RemindSync::SyncPlanner.plan(**kwargs)
  end

  def assert_empty_plan(p)
    assert_empty p["reminder_actions"]
    assert_empty p["memory_actions"]
    assert_empty p["capture_candidates"]
    assert_equal 0, p["counts"].values.sum
  end
end

class TestSyncPlannerRules < Minitest::Test
  include RemindSyncTestHelpers

  # Rule 1: open, unlinked, unreferenced reminder in a capture list.
  def test_rule1_capture_candidate
    r = reminder(id: "r1", list: "Inbox", title: "buy milk", notes: "some note", due: "2026-07-10T00:00:00+09:00")
    p = plan(reminders: [r], memory_items: [])

    assert_equal 1, p["capture_candidates"].size
    c = p["capture_candidates"].first
    assert_equal({ "id" => "r1", "externalId" => "ext-r1", "title" => "buy milk",
                   "notes" => "some note", "due" => "2026-07-10T00:00:00+09:00",
                   "list" => "Inbox" }, c)
    assert_empty p["reminder_actions"]
    assert_empty p["memory_actions"]
    assert_equal 1, p["counts"]["capture_candidates"]
  end

  # Capture lists = config capture lists + mirror list: a user-created reminder
  # directly in the mirror list is also a capture candidate.
  def test_rule1_mirror_list_is_a_capture_list
    r = reminder(id: "r1", list: "Claude", title: "typed straight into Claude list")
    p = plan(reminders: [r], memory_items: [])

    assert_equal ["r1"], p["capture_candidates"].map { |c| c["id"] }
  end

  def test_rule1_ignores_non_capture_list
    r = reminder(id: "r1", list: "Groceries")
    p = plan(reminders: [r], memory_items: [])

    assert_empty_plan p
  end

  # Rule 1 horizon: far-future scheduled reminders stay in Reminders (which
  # owns their notification) — they are NOT capture candidates.
  def test_rule1_horizon_excludes_far_future_due
    now = Time.iso8601("2026-07-08T00:00:00+09:00")
    r = reminder(id: "r1", list: "Inbox", due: "2026-12-31T00:00:00+09:00")
    p = plan(reminders: [r], memory_items: [], now: now)

    assert_empty_plan p
  end

  def test_rule1_horizon_includes_near_due
    now = Time.iso8601("2026-07-08T00:00:00+09:00")
    r = reminder(id: "r1", list: "Inbox", due: "2026-07-15T00:00:00+09:00")
    p = plan(reminders: [r], memory_items: [], now: now)

    assert_equal ["r1"], p["capture_candidates"].map { |c| c["id"] }
  end

  def test_rule1_horizon_negative_disables_filter
    now = Time.iso8601("2026-07-08T00:00:00+09:00")
    cfg = config
    cfg["capture"]["due_horizon_days"] = -1
    r = reminder(id: "r1", list: "Inbox", due: "2027-06-30T00:00:00+09:00")
    p = plan(reminders: [r], memory_items: [], cfg: cfg, now: now)

    assert_equal ["r1"], p["capture_candidates"].map { |c| c["id"] }
  end

  def test_rule1_horizon_custom_days
    now = Time.iso8601("2026-07-08T00:00:00+09:00")
    cfg = config
    cfg["capture"]["due_horizon_days"] = 1
    r = reminder(id: "r1", list: "Inbox", due: "2026-07-11T00:00:00+09:00")
    p = plan(reminders: [r], memory_items: [], cfg: cfg, now: now)

    assert_empty_plan p
  end

  # Rule 2: memory item references the reminder by externalId -> annotate.
  def test_rule2_annotate_by_external_id
    r = reminder(id: "r1", list: "Inbox")
    m = memory_item(id: "m1", content: "TODO: buy milk。完了条件: bought reminders:ext-r1")
    p = plan(reminders: [r], memory_items: [m])

    assert_equal [{ "op" => "annotate", "id" => "r1", "notes" => "[ai-todo:m1]" }],
                 p["reminder_actions"]
    assert_empty p["capture_candidates"] # referenced -> no longer a candidate
    assert_empty p["memory_actions"]
    # refs(m) non-empty -> reminder-derived -> no create_mirror either
    assert_equal 0, p["counts"]["add"]
  end

  # "id でも extId でも可": reference by the reminder's own id also links.
  def test_rule2_annotate_by_reminder_id
    r = reminder(id: "r1", list: "Inbox")
    m = memory_item(id: "m1", content: "captured reminders:r1")
    p = plan(reminders: [r], memory_items: [m])

    assert_equal [{ "op" => "annotate", "id" => "r1", "notes" => "[ai-todo:m1]" }],
                 p["reminder_actions"]
  end

  # Rule 3: open memory item, no refs, no mirror reminder -> mklist + add.
  def test_rule3_create_mirror_with_mklist_at_head
    m = memory_item(id: "m1", content: "TODO: write the report。完了条件: report sent")
    p = plan(reminders: [], memory_items: [m])

    assert_equal %w[mklist add], p["reminder_actions"].map { |a| a["op"] }
    assert_equal({ "op" => "mklist", "list" => "Claude" }, p["reminder_actions"][0])
    add = p["reminder_actions"][1]
    assert_equal "Claude", add["list"]
    assert_equal "write the report", add["title"]
    assert_equal "[ai-todo:m1]", add["notes"].lines.last.chomp
    assert_equal 1, p["counts"]["mklist"]
    assert_equal 1, p["counts"]["add"]
  end

  def test_rule3_no_mklist_when_no_adds
    r = reminder(id: "r1", list: "Inbox")
    p = plan(reminders: [r], memory_items: [])

    refute p["reminder_actions"].any? { |a| a["op"] == "mklist" }
    assert_equal 0, p["counts"]["mklist"]
  end

  def test_rule3_skipped_when_mirror_reminder_exists
    m = memory_item(id: "m1", content: "TODO: write the report。")
    r = reminder(id: "r1", list: "Claude", notes: "[ai-todo:m1]")
    p = plan(reminders: [r], memory_items: [m])

    assert_empty_plan p # fully in sync
  end

  # A completed mirror reminder still blocks re-creation (rule 4 handles it).
  def test_rule3_skipped_when_mirror_reminder_completed
    m = memory_item(id: "m1", content: "TODO: write the report。")
    r = reminder(id: "r1", list: "Claude", notes: "[ai-todo:m1]", completed: true)
    p = plan(reminders: [r], memory_items: [m])

    refute p["reminder_actions"].any? { |a| a["op"] == "add" }
    assert_equal 1, p["counts"]["forget"] # rule 4 fires instead
  end

  # Rule 4: completed reminder linked to an open memory item -> forget.
  def test_rule4_forget_on_completed_linked_reminder
    m = memory_item(id: "m1", content: "TODO: write the report。", store: "ai-memory")
    r = reminder(id: "r1", list: "Claude", notes: "done stuff\n[ai-todo:m1]", completed: true)
    p = plan(reminders: [r], memory_items: [m])

    assert_equal 1, p["memory_actions"].size
    f = p["memory_actions"].first
    assert_equal "forget", f["op"]
    assert_equal "ai-memory", f["store"]
    assert_equal "m1", f["id"]
    assert_includes f["reason"], "r1"
    refute p["reminder_actions"].any? { |a| a["op"] == "complete" } # already completed
  end

  # Rule 5: open reminder whose token no longer matches any open memory item.
  def test_rule5_complete_on_stale_token
    r = reminder(id: "r1", list: "Claude", notes: "[ai-todo:gone]")
    p = plan(reminders: [r], memory_items: [])

    assert_equal [{ "op" => "complete", "id" => "r1" }], p["reminder_actions"]
    assert_equal 1, p["counts"]["complete"]
  end

  # complete_captured=false gate: only mirror-list reminders are auto-completed.
  def test_rule5_complete_captured_false_gate
    cfg = config(complete_captured: false)
    r_capture = reminder(id: "r1", list: "Inbox", notes: "[ai-todo:gone]")
    r_mirror = reminder(id: "r2", list: "Claude", notes: "[ai-todo:gone]")
    p = plan(reminders: [r_capture, r_mirror], memory_items: [], cfg: cfg)

    completes = p["reminder_actions"].select { |a| a["op"] == "complete" }
    assert_equal ["r2"], completes.map { |a| a["id"] }
  end

  def test_rule5_complete_captured_true_applies_to_capture_lists
    r_capture = reminder(id: "r1", list: "Inbox", notes: "[ai-todo:gone]")
    p = plan(reminders: [r_capture], memory_items: [])

    assert_equal [{ "op" => "complete", "id" => "r1" }], p["reminder_actions"]
  end

  # Completed, unlinked, unreferenced capture-list reminder matches no rule.
  def test_completed_unlinked_capture_reminder_ignored
    r = reminder(id: "r1", list: "Inbox", completed: true)
    p = plan(reminders: [r], memory_items: [])

    assert_empty_plan p
  end

  # Egress guard: a store absent from mirror.stores is never mirrored.
  def test_egress_guard_unlisted_store_not_mirrored
    m = memory_item(id: "m1", content: "TODO (work): internal thing。", store: "memory-work")
    p = plan(reminders: [], memory_items: [m])

    assert_empty p["reminder_actions"]
    assert_equal 0, p["counts"]["add"]
  end

  # Last [ai-todo:] match wins: M contains the OLD token, so a first-match
  # implementation would see the reminder as in-sync; last-match completes it.
  def test_token_last_match_wins
    m_old = memory_item(id: "old", content: "TODO: old。")
    r = reminder(id: "r1", list: "Claude", notes: "[ai-todo:old]\n[ai-todo:new]")
    p = plan(reminders: [r], memory_items: [m_old])

    assert_includes p["reminder_actions"], { "op" => "complete", "id" => "r1" }
  end
end

class TestMirrorContentPolicy < Minitest::Test
  include RemindSyncTestHelpers

  FULL_CONTENT = "TODO: レビュー対応する。詳細は PR 参照。\n" \
                 "完了条件: 全コメント resolve 済み\n" \
                 "https://github.com/o/r/pull/1\n" \
                 "期日: 2026-07-15"

  def add_for(content, store: "ai-memory", stores: [{ "name" => "ai-memory", "policy" => "full" }])
    m = memory_item(id: "m1", content: content, store: store)
    p = plan(reminders: [], memory_items: [m], cfg: config(stores: stores))
    p["reminder_actions"].find { |a| a["op"] == "add" }
  end

  def test_policy_full_notes_completion_url_token
    add = add_for(FULL_CONTENT)

    assert_equal "完了条件: 全コメント resolve 済み\nhttps://github.com/o/r/pull/1\n[ai-todo:m1]",
                 add["notes"]
    assert_equal "[ai-todo:m1]", add["notes"].lines.last.chomp # token line is last
  end

  def test_policy_title_link_notes_url_and_token_only
    add = add_for(FULL_CONTENT.sub("TODO: ", "TODO (work): "),
                  store: "memory-work",
                  stores: [{ "name" => "memory-work", "policy" => "title-link" }])

    assert_equal "https://github.com/o/r/pull/1\n[ai-todo:m1]", add["notes"]
    refute_includes add["notes"], "完了条件" # body never leaves for iCloud
  end

  def test_policy_full_without_completion_or_url
    add = add_for("TODO: simple thing。")

    assert_equal "[ai-todo:m1]", add["notes"]
  end

  def test_due_extracted_date_only
    add = add_for(FULL_CONTENT)

    assert_equal "2026-07-15", add["due"]
  end

  def test_due_extracted_with_time
    add = add_for("TODO: x。期日: 2026-07-15 09:30")

    assert_equal "2026-07-15 09:30", add["due"]
  end

  def test_due_absent_without_keyword
    add = add_for("TODO: x。deadline is 2026-07-15")

    refute add.key?("due")
  end

  def test_title_strips_work_prefix_and_cuts_at_sentence
    add = add_for("TODO (work): zp の PR を片付ける。完了条件: merge")

    assert_equal "zp の PR を片付ける", add["title"]
  end

  def test_title_strips_plain_todo_prefix
    add = add_for("TODO: fix the flaky test。")

    assert_equal "fix the flaky test", add["title"]
  end

  def test_title_truncated_at_100_chars
    add = add_for("TODO: #{"x" * 150}")

    assert_equal 100, add["title"].length
    assert_equal "x" * 100, add["title"]
  end

  def test_title_whole_content_when_no_sentence_end
    add = add_for("short task without period")

    assert_equal "short task without period", add["title"]
  end
end

class TestFixpointConvergence < Minitest::Test
  include RemindSyncTestHelpers

  # Capture flow: candidate -> (collector remembers) -> annotate -> in sync.
  def test_capture_then_annotate_then_converged
    r = reminder(id: "r1", list: "Inbox", title: "call the dentist")

    # Pass 1: raw user reminder is only a capture candidate.
    p1 = plan(reminders: [r], memory_items: [])
    assert_equal ["r1"], p1["capture_candidates"].map { |c| c["id"] }
    assert_empty p1["reminder_actions"]

    # Collector saved it to memory with reminders:<extId> provenance.
    m = memory_item(id: "m1", content: "TODO: call the dentist。完了条件: booked reminders:ext-r1")

    # Pass 2: annotate appears (and the candidate disappears).
    p2 = plan(reminders: [r], memory_items: [m])
    assert_equal [{ "op" => "annotate", "id" => "r1", "notes" => "[ai-todo:m1]" }],
                 p2["reminder_actions"]
    assert_empty p2["capture_candidates"]

    # Simulate the annotate apply (remind CLI appends on a new line).
    r_annotated = r.merge("notes" => "[ai-todo:m1]")

    # Pass 3: fully converged — every rule yields zero.
    assert_empty_plan plan(reminders: [r_annotated], memory_items: [m])
  end

  # Mirror flow: add -> in sync -> user completes -> forget -> empty.
  def test_mirror_create_complete_forget_lifecycle
    m = memory_item(id: "m1", content: "TODO: write the report。完了条件: sent")

    # Pass 1: mklist + add.
    p1 = plan(reminders: [], memory_items: [m])
    assert_equal %w[mklist add], p1["reminder_actions"].map { |a| a["op"] }

    # Simulate the applied add.
    mirrored = reminder(id: "r1", list: "Claude", title: p1["reminder_actions"][1]["title"],
                        notes: p1["reminder_actions"][1]["notes"])

    # Pass 2: converged.
    assert_empty_plan plan(reminders: [mirrored], memory_items: [m])

    # User completes the mirror reminder on iOS.
    done = mirrored.merge("completed" => true)
    p3 = plan(reminders: [done], memory_items: [m])
    assert_equal [{ "op" => "forget", "store" => "ai-memory", "id" => "m1",
                    "reason" => "linked reminder completed (r1)" }], p3["memory_actions"]
    assert_empty p3["reminder_actions"]

    # Caller executed the forget; memory item gone -> everything is quiet
    # (completed reminder with stale token matches neither rule 4 nor 5).
    assert_empty_plan plan(reminders: [done], memory_items: [])
  end
end

# Stub runner: records argv calls, returns canned [output, exit_code].
class StubRunner
  attr_reader :calls

  def initialize(&responder)
    @calls = []
    @responder = responder || ->(_argv) { ["", 0] }
  end

  def to_proc
    method(:call).to_proc
  end

  def call(argv)
    @calls << argv
    @responder.call(argv)
  end
end

class TestReminderStore < Minitest::Test
  include RemindSyncTestHelpers

  BIN = "/stub/remind"

  def store_with(runner)
    RemindSync::ReminderStore.new(bin: BIN, runner: runner)
  end

  def test_dump_argv_and_parse
    dumped = [reminder(id: "r1", list: "Inbox")]
    runner = StubRunner.new { |_argv| [JSON.generate(dumped), 0] }
    result = store_with(runner).dump(list: "Inbox", include_completed: true)

    assert_equal [[BIN, "--dump", "--list", "Inbox", "--include-completed"]], runner.calls
    assert_equal dumped, result
  end

  def test_dump_raises_on_failure
    runner = StubRunner.new { |_argv| ["boom", 1] }
    err = assert_raises(RuntimeError) { store_with(runner).dump(list: "Inbox") }
    assert_includes err.message, "Inbox"
  end

  def test_argv_for_each_op
    store = store_with(StubRunner.new)

    assert_equal [BIN, "--mklist", "Claude"],
                 store.argv_for({ "op" => "mklist", "list" => "Claude" })
    assert_equal [BIN, "task", "--list", "Claude", "--notes", "n\n[ai-todo:m1]", "--due", "2026-07-15"],
                 store.argv_for({ "op" => "add", "list" => "Claude", "title" => "task",
                                  "notes" => "n\n[ai-todo:m1]", "due" => "2026-07-15" })
    assert_equal [BIN, "task", "--list", "Claude", "--notes", "[ai-todo:m1]"],
                 store.argv_for({ "op" => "add", "list" => "Claude", "title" => "task",
                                  "notes" => "[ai-todo:m1]" }) # no --due without a due
    assert_equal [BIN, "--annotate", "r1", "--notes", "[ai-todo:m1]"],
                 store.argv_for({ "op" => "annotate", "id" => "r1", "notes" => "[ai-todo:m1]" })
    assert_equal [BIN, "--complete", "r1"],
                 store.argv_for({ "op" => "complete", "id" => "r1" })
    assert_raises(ArgumentError) { store.argv_for({ "op" => "nuke" }) }
  end

  def test_bin_resolution_precedence
    orig = ENV["REMIND_BIN"]
    ENV["REMIND_BIN"] = "/env/remind"
    assert_equal "/env/remind", RemindSync::ReminderStore.new.bin
    assert_equal "/flag/remind", RemindSync::ReminderStore.new(bin: "/flag/remind").bin
  ensure
    orig.nil? ? ENV.delete("REMIND_BIN") : ENV["REMIND_BIN"] = orig
  end
end

class TestApplyActions < Minitest::Test
  include RemindSyncTestHelpers

  BIN = "/stub/remind"

  ACTIONS = [
    { "op" => "complete", "id" => "r9" },
    { "op" => "annotate", "id" => "r1", "notes" => "[ai-todo:m1]" },
    { "op" => "add", "list" => "Claude", "title" => "t", "notes" => "[ai-todo:m2]" },
    { "op" => "mklist", "list" => "Claude" }
  ].freeze

  def test_apply_order_mklist_add_annotate_complete
    runner = StubRunner.new
    store = RemindSync::ReminderStore.new(bin: BIN, runner: runner)
    applied, failures = RemindSync.apply_actions(ACTIONS, store, stderr: StringIO.new)

    assert_equal 4, applied
    assert_empty failures
    assert_equal ["--mklist", "t", "--annotate", "--complete"],
                 runner.calls.map { |argv| argv[1] }
  end

  def test_apply_counts_partial_failure_and_reports_stderr
    runner = StubRunner.new { |argv| argv.include?("--complete") ? ["denied", 1] : ["", 0] }
    store = RemindSync::ReminderStore.new(bin: BIN, runner: runner)
    stderr = StringIO.new
    applied, failures = RemindSync.apply_actions(ACTIONS, store, stderr: stderr)

    assert_equal 3, applied
    assert_equal 1, failures.size
    assert_equal({ "op" => "complete", "id" => "r9" }, failures.first["action"])
    assert_includes stderr.string, "FAILED"
    assert_includes stderr.string, "denied"
  end
end

class TestMainEntry < Minitest::Test
  def test_main_returns_2_without_required_args
    rc = nil
    capture_io { rc = RemindSync.main([]) }
    assert_equal 2, rc
  end
end
