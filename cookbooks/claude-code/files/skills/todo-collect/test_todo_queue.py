#!/usr/bin/env python3
"""Unit tests for todo_queue.py (stdlib unittest).

    python3 -m unittest cookbooks/claude-code/files/skills/todo-collect/test_todo_queue.py -v

Test-only; the cookbook does not deploy this file (same as test_remind_sync.rb).
"""

import contextlib
import datetime as dt
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import todo_queue as tq  # noqa: E402

TODAY = "2026-09-04"
NOW = "2026-09-04T22:24:26Z"
RUN = "2026-09-04T22:24:26Z-12345"
HOST_A = "https://mercari.slack.com/archives/C0A4XE8GF0F/p1787227341426699"
HOST_B = "https://mercari.enterprise.slack.com/archives/C0A4XE8GF0F/p1787227341426699"
KEY_A = "slack:C0A4XE8GF0F/1787227341.426699"


def item(**kw):
    base = {
        "source": "work-slack-saved",
        "class": "inferred",
        "title": "t",
        "permalink": HOST_A,
        "origin_ts": "2026-08-28T09:55:10+09:00",
        "draft_close_condition": "reply",
    }
    base.update(kw)
    return base


def env(state="complete", records=None, **kw):
    e = {"state": state, "total": len(records or []), "returned": len(records or []), "remaining": 0, "reason": ""}
    e.update(kw)
    return {"enum": e, "records": records or []}


def sweep(items=None, sources=None, todos=None, dispositions=None, run=RUN):
    doc = {
        "run": run,
        "sources": sources if sources is not None else [{"name": "work-slack-saved", "class": "inferred", "status": "swept", "count": 1}],
        "items": items if items is not None else [item()],
    }
    doc["todos"] = todos if todos is not None else env()
    doc["dispositions"] = dispositions if dispositions is not None else env()
    return doc


def disp(kind, key, written_at="2026-09-01T00:00:00Z", **fields):
    rest = " ".join(f"{k}={v}" for k, v in fields.items())
    return {"id": "d1", "content": f"todo-disposition {kind} key={key} written_at={written_at} {rest}".strip() + "\n理由"}


def todo_record(key):
    return {"id": "t1", "content": f"key={key}\n完了条件: x", "tags": ["todo"]}


CONFIG = {"queue": {"ttl_days": 21}, "sources": [{"name": "work-slack-saved", "class": "inferred", "max_age_days": 30}]}


def run_filter(prev_rows, doc, config=CONFIG, today=TODAY):
    return tq.filter_queue(prev_rows, doc, config, RUN, dt.date.fromisoformat(today), NOW)


def other_permalink(suffix):
    return HOST_A.replace("p1787227341426699", f"p17872273414267{suffix:02d}")


class KeyNormalization(unittest.TestCase):
    def test_slack_key_same_for_both_hosts(self):
        ka, _ = tq.slack_key_from_permalink(HOST_A)
        kb, _ = tq.slack_key_from_permalink(HOST_B)
        self.assertEqual(ka, KEY_A)
        self.assertEqual(ka, kb)

    def test_slack_thread_key_from_thread_ts_and_defaults_to_key(self):
        _, t = tq.slack_key_from_permalink(HOST_A + "?thread_ts=1787200000.000100&cid=C0A4XE8GF0F")
        self.assertEqual(t, "slack:C0A4XE8GF0F/1787200000.000100")
        k2, t2 = tq.slack_key_from_permalink(HOST_A)
        self.assertEqual(k2, t2)

    def test_notion_key_uses_block_anchor_else_idx(self):
        k, t = tq.notion_key_from_permalink(
            "https://www.notion.so/MP-PM-3667fa9ffaef80de8411fec6bd0a692c#3667fa9ffaef809ba57df4021eb30ce6"
        )
        self.assertEqual(k, "notion:3667fa9ffaef80de8411fec6bd0a692c#3667fa9ffaef809ba57df4021eb30ce6")
        self.assertEqual(t, "notion:3667fa9ffaef80de8411fec6bd0a692c")
        k2, _ = tq.notion_key_from_permalink("https://app.notion.com/p/NASA-v0-3bf7fa9ffaef81f38013e3e7f153cbe7", idx=2)
        self.assertEqual(k2, "notion:3bf7fa9ffaef81f38013e3e7f153cbe7#2")

    def test_item_without_key_or_permalink_fails_validation(self):
        errors = tq.validate_sweep(sweep(items=[item(permalink="https://example.com/x")]), run=RUN)
        self.assertTrue(any("canonical key" in e for e in errors))

    def test_canonical_key_passthrough(self):
        self.assertEqual(tq.canonical_key({"key": "transcript:abc:12"}), ("transcript:abc:12", "transcript:abc:12"))


class EnumValidation(unittest.TestCase):
    def test_rejects_unknown_source_status(self):
        errors = tq.validate_sweep(sweep(sources=[{"name": "s", "status": "partial"}]), run=RUN)
        self.assertTrue(any("sources[0].status" in e for e in errors))

    def test_truncated_requires_remaining_int_or_unknown(self):
        bad = tq.validate_sweep(sweep(sources=[{"name": "s", "status": "truncated"}]), run=RUN)
        self.assertTrue(any("remaining" in e for e in bad))
        self.assertEqual(tq.validate_sweep(sweep(sources=[{"name": "s", "status": "truncated", "remaining": 12}]), run=RUN), [])
        self.assertEqual(tq.validate_sweep(sweep(sources=[{"name": "s", "status": "truncated", "remaining": "unknown"}]), run=RUN), [])

    def test_unswept_requires_reason(self):
        errors = tq.validate_sweep(sweep(sources=[{"name": "s", "status": "unswept"}]), run=RUN)
        self.assertTrue(any("reason" in e for e in errors))

    def test_dispositions_unreached_requires_reason(self):
        errors = tq.validate_sweep(sweep(dispositions={"enum": {"state": "unreached"}, "records": []}), run=RUN)
        self.assertTrue(any("dispositions.enum.reason" in e for e in errors))

    def test_missing_envelope_becomes_unreached_not_silent(self):
        doc = sweep()
        del doc["dispositions"]
        self.assertEqual(tq.validate_sweep(doc, run=RUN), [])
        meta, _, _ = run_filter([], doc)
        self.assertEqual(meta["dispositions_enum"]["state"], "unreached")
        self.assertIn("absent", meta["dispositions_enum"]["reason"])
        self.assertEqual(meta["filters_skipped"], ["disposition", "snooze"])

    def test_run_mismatch_is_an_error(self):
        errors = tq.validate_sweep(sweep(run="other"), run=RUN)
        self.assertTrue(any("run" in e for e in errors))


class Filter(unittest.TestCase):
    def test_aging_boundary_exact_kept_one_day_over_aged(self):
        exact = item(origin_ts="2026-08-05T10:00:00+09:00")  # 30 days before TODAY
        over = item(origin_ts="2026-08-04T10:00:00+09:00", permalink=other_permalink(1))
        meta, _, report = run_filter([], sweep(items=[exact, over]))
        self.assertEqual(meta["open"], 1)
        self.assertEqual(meta["aged_out"], 1)
        self.assertEqual(report["aged_out_keys"][0]["age_days"], 31)

    def test_aging_ignores_explicit_and_missing_max_age(self):
        old_explicit = item(**{"class": "explicit", "source": "work-slack-pin", "origin_ts": "2026-01-01T00:00:00Z"})
        old_unconfigured = item(source="other", origin_ts="2026-01-01T00:00:00Z", permalink=other_permalink(2))
        meta, _, _ = run_filter([], sweep(items=[old_explicit, old_unconfigured]))
        self.assertEqual(meta["open"], 2)
        self.assertEqual(meta["aged_out"], 0)

    def test_missing_origin_ts_kept_and_flagged(self):
        meta, _, _ = run_filter([], sweep(items=[item(origin_ts=None)]))
        self.assertEqual(meta["open"], 1)
        self.assertEqual(meta["origin_ts_missing"], [KEY_A])

    def test_dedup_by_key_line_in_todo_records(self):
        meta, _, _ = run_filter([], sweep(todos=env(records=[todo_record(KEY_A)])))
        self.assertEqual(meta["open"], 0)
        self.assertEqual(meta["deduped"], 1)

    def test_done_disposition_hides_explicit_and_inferred_key(self):
        for klass in ("inferred", "explicit"):
            doc = sweep(items=[item(**{"class": klass})], dispositions=env(records=[disp("done", KEY_A)]))
            meta, _, _ = run_filter([], doc)
            self.assertEqual(meta["open"], 0, klass)
            self.assertEqual(meta["rejected_hidden"], 1, klass)

    def test_reject_then_revive_latest_written_at_wins(self):
        recs = [disp("reject", KEY_A, "2026-09-01T00:00:00Z"), disp("revive", KEY_A, "2026-09-02T00:00:00Z")]
        meta, _, _ = run_filter([], sweep(dispositions=env(records=recs)))
        self.assertEqual(meta["open"], 1)
        recs_rev = [disp("revive", KEY_A, "2026-09-01T00:00:00Z"), disp("reject", KEY_A, "2026-09-02T00:00:00Z")]
        meta2, _, _ = run_filter([], sweep(dispositions=env(records=recs_rev)))
        self.assertEqual(meta2["open"], 0)

    def test_never_with_thread_key_hides_thread_siblings(self):
        sibling = item(permalink=other_permalink(5) + "?thread_ts=1787227341.426699")
        recs = [disp("never", KEY_A, thread_key=KEY_A)]
        meta, _, report = run_filter([], sweep(items=[sibling], dispositions=env(records=recs)))
        self.assertEqual(meta["open"], 0)
        self.assertEqual(report["hidden"][0]["kind"], "never-thread")

    def test_reject_without_thread_key_hides_only_that_key(self):
        sibling = item(permalink=other_permalink(5) + "?thread_ts=1787227341.426699")
        meta, rows, _ = run_filter([], sweep(items=[item(), sibling], dispositions=env(records=[disp("reject", KEY_A)])))
        self.assertEqual(meta["open"], 1)
        self.assertEqual(rows[0]["key"], "slack:C0A4XE8GF0F/1787227341.426705")

    def test_snooze_until_future_hidden_past_wakes_with_snooze_wake(self):
        meta, _, _ = run_filter([], sweep(dispositions=env(records=[disp("snooze", KEY_A, until="2026-09-10")])))
        self.assertEqual(meta["snoozed_hidden"], 1)
        meta2, rows2, _ = run_filter([], sweep(dispositions=env(records=[disp("snooze", KEY_A, until="2026-09-01")])))
        self.assertEqual(meta2["open"], 1)
        self.assertEqual(rows2[0]["snooze_wake"], "2026-09-01")

    def test_dispositions_truncated_skips_filters_and_sets_filters_skipped(self):
        e = env(state="truncated", records=[disp("reject", KEY_A)], remaining="unknown")
        meta, _, _ = run_filter([], sweep(dispositions=e))
        self.assertEqual(meta["open"], 1)
        self.assertEqual(meta["filters_skipped"], ["disposition", "snooze"])

    def test_ttl_expired_by_first_seen_listed_not_written(self):
        prev = [{"type": "candidate", "key": KEY_A, "first_seen": "2026-08-01", "state": "open"}]
        meta, rows, report = run_filter(prev, sweep())
        self.assertEqual(rows, [])
        self.assertEqual(meta["expired"], 1)
        self.assertEqual(meta["expired_keys"], [KEY_A])
        self.assertEqual(report["expired_keys"][0]["first_seen"], "2026-08-01")

    def test_first_seen_carried_from_prev_else_today(self):
        prev = [{"type": "candidate", "key": KEY_A, "first_seen": "2026-08-30", "state": "needs_review",
                 "announce": {"channel": "D1", "ts": "1.0"}}]
        meta, rows, _ = run_filter(prev, sweep())
        self.assertEqual(rows[0]["first_seen"], "2026-08-30")
        self.assertEqual(rows[0]["state"], "needs_review")
        self.assertEqual(rows[0]["announce"], {"channel": "D1", "ts": "1.0"})
        self.assertEqual(meta["announced"], 1)
        _, rows2, _ = run_filter([], sweep())
        self.assertEqual(rows2[0]["first_seen"], TODAY)

    def test_meta_counts_equal_rows_and_sorted_stable(self):
        a = item(origin_ts="2026-08-30T00:00:00Z")
        b = item(origin_ts="2026-08-29T00:00:00Z", permalink=other_permalink(0))
        meta, rows, _ = run_filter([], sweep(items=[a, b]))
        self.assertEqual(meta["open"] + meta["needs_review"], len(rows))
        self.assertEqual([r["origin_ts"] for r in rows], ["2026-08-29T00:00:00Z", "2026-08-30T00:00:00Z"])

    def test_done_key_resweep_yields_open_zero(self):
        meta, _, _ = run_filter([], sweep(items=[item(**{"class": "explicit"})], dispositions=env(records=[disp("done", KEY_A)])))
        self.assertEqual(meta["open"], 0)

    def test_rejected_key_resweep_yields_open_zero(self):
        meta, _, _ = run_filter([], sweep(dispositions=env(records=[disp("reject", KEY_A)])))
        self.assertEqual(meta["open"], 0)
        self.assertEqual(meta["rejected_hidden"], 1)

    def test_intra_sweep_duplicate_key_first_wins(self):
        meta, rows, _ = run_filter([], sweep(items=[item(title="first"), item(title="second", permalink=HOST_B)]))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["title"], "first")
        self.assertEqual(meta["deduped"], 1)


class FilesAndCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "todo"
        self.dir.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = tq.main(["--todo-dir", str(self.dir), "--now", NOW, "--today", TODAY, *argv])
        return rc, out.getvalue(), err.getvalue()

    def write(self, name, obj):
        p = self.dir / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(obj), encoding="utf-8")
        return p

    def test_init_moves_legacy_and_writes_3_line_index(self):
        legacy = ("# TODO Ledger\n\n## smoke run 2026-07-07T01:00:00Z-1\n- x\n\n"
                  "## /todo-collect run 2026-08-30T22:26:26Z-2477270\n- y\n")
        (self.dir / "ledger.md").write_text(legacy, encoding="utf-8")
        rc, out, _ = self.run_cli("init")
        self.assertEqual(rc, 0)
        res = json.loads(out)
        self.assertTrue(res["migrated"])
        self.assertTrue(res["legacy"].endswith("runs/0000-legacy-ledger-2026-07-07_2026-08-30.md"))
        self.assertEqual(Path(res["legacy"]).read_text(encoding="utf-8"), legacy)
        index = (self.dir / "ledger.md").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(index), 3)
        self.assertIn("| migrate |", index[2])
        meta, rows = tq.read_queue(self.dir / "candidates.jsonl")
        self.assertEqual(meta["run"], "init")
        self.assertEqual(rows, [])
        self.assertTrue((self.dir / "runs").is_dir() and (self.dir / "tmp").is_dir())

    def test_init_twice_is_noop(self):
        (self.dir / "ledger.md").write_text("## run 2026-08-01\n", encoding="utf-8")
        self.run_cli("init")
        before = sorted(p.name for p in (self.dir / "runs").iterdir())
        rc, out, _ = self.run_cli("init")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out), {"migrated": False, "legacy": None, "created": []})
        self.assertEqual(before, sorted(p.name for p in (self.dir / "runs").iterdir()))

    def test_init_leaves_index_style_ledger_alone(self):
        (self.dir / "ledger.md").write_text("# index\n2026-09-01 | collect | r | ok | s | runs/x.md\n", encoding="utf-8")
        rc, out, _ = self.run_cli("init")
        self.assertEqual(rc, 0)
        self.assertFalse(json.loads(out)["migrated"])
        self.assertEqual((self.dir / "ledger.md").read_text(encoding="utf-8").splitlines()[0], "# index")

    def test_filter_writes_queue_atomically_and_run_log(self):
        sw = self.write("tmp/sweep.json", sweep())
        cfg = self.write("tmp/config.json", CONFIG)
        run_log = self.dir / "runs" / f"{RUN}-collect.md"
        rc, out, err = self.run_cli("filter", "--sweep", str(sw), "--run", RUN, "--config", str(cfg), "--run-log", str(run_log))
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out)["open"], 1)
        meta, rows = tq.read_queue(self.dir / "candidates.jsonl")
        self.assertEqual(meta["run"], RUN)
        self.assertEqual(len(rows), 1)
        self.assertEqual([p.name for p in self.dir.iterdir() if p.name.startswith(".candidates")], [])
        self.assertIn("### queue filter", run_log.read_text(encoding="utf-8"))

    def test_run_log_receives_one_line_per_aged_out_key(self):
        sw = self.write("tmp/sweep.json", sweep(items=[item(origin_ts="2026-01-01T00:00:00Z")]))
        cfg = self.write("tmp/config.json", CONFIG)
        run_log = self.dir / "runs" / "x.md"
        rc, _, _ = self.run_cli("filter", "--sweep", str(sw), "--run", RUN, "--config", str(cfg), "--run-log", str(run_log))
        self.assertEqual(rc, 0)
        self.assertEqual(run_log.read_text(encoding="utf-8").count("- aged-out "), 1)

    def test_filter_bad_enum_exits_3(self):
        sw = self.write("tmp/sweep.json", sweep(sources=[{"name": "s", "status": "zero"}]))
        rc, _, err = self.run_cli("filter", "--sweep", str(sw), "--run", RUN)
        self.assertEqual(rc, 3)
        self.assertIn("status", err)

    def test_invalid_json_exits_4(self):
        p = self.dir / "tmp" / "bad.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("{not json", encoding="utf-8")
        rc, _, _ = self.run_cli("validate", "--sweep", str(p))
        self.assertEqual(rc, 4)

    def test_usage_exit_2(self):
        rc, _, _ = self.run_cli("validate")
        self.assertEqual(rc, 2)

    def test_validate_queue_detects_stale_run(self):
        sw = self.write("tmp/sweep.json", sweep())
        self.run_cli("filter", "--sweep", str(sw), "--run", RUN)
        rc, _, err = self.run_cli("validate", "--queue", str(self.dir / "candidates.jsonl"), "--run", "other-run")
        self.assertEqual(rc, 3)
        self.assertIn("meta.run", err)

    def test_summary_prs_null_renders_fetch_failed(self):
        self.write("prs.json", {"written_at": NOW, "run": RUN, "error": "gh failed", "prs": None})
        rc, out, _ = self.run_cli("summary")
        self.assertEqual(rc, 0)
        self.assertIn("prs: fetch failed (gh failed)", out)

    def test_summary_reports_disabled_sentinel_and_last_age(self):
        logs = self.dir.parent / "logs"
        logs.mkdir()
        (logs / "todo-collect.last").write_text("2026-09-02T22:31:44Z\n", encoding="utf-8")
        (self.dir.parent / "todo-collect.DISABLED").write_text("", encoding="utf-8")
        rc, out, _ = self.run_cli("summary", "--logs", str(logs))
        self.assertEqual(rc, 0)
        self.assertIn("disabled: todo-collect.DISABLED", out)
        self.assertIn("loop todo-collect: last ok 2026-09-02T22:31:44Z (47.9h ago)", out)
        self.assertIn("stale: todo-collect", out)
        (logs / "todo-collect.last").write_text("2026-09-04T00:00:00Z\n", encoding="utf-8")
        rc, out, _ = self.run_cli("summary", "--logs", str(logs))
        self.assertIn("(22.4h ago)", out)
        self.assertNotIn("stale:", out)

    def test_summary_survives_missing_files(self):
        rc, out, _ = self.run_cli("summary")
        self.assertEqual(rc, 0)
        self.assertIn("queue: no data", out)
        self.assertIn("stores: no data", out)
        self.assertIn("prs: no data", out)
        self.assertLessEqual(len(out.strip().splitlines()), 20)

    def test_summary_json_shape(self):
        rc, out, _ = self.run_cli("summary", "--json")
        self.assertEqual(rc, 0)
        self.assertIn("loops", json.loads(out))


SLACK_CONFIG = {
    "queue": {"ttl_days": 21, "dm_per_run_max": 2, "snooze_days": 7},
    "sources": [{"name": "work-slack-saved", "class": "inferred", "max_age_days": 30}],
    "surfaces": {"queue_surface": "slack-self-dm", "channel": "D1", "reactions": {"approve": "white_check_mark", "reject": "x", "snooze": "zzz", "never": "mute"}},
}


def row(key=KEY_A, **kw):
    base = {"type": "candidate", "key": key, "thread_key": key, "source": "work-slack-saved", "class": "inferred",
            "title": "t", "permalink": HOST_A, "origin_ts": "2026-08-28T09:55:10+09:00", "due": None,
            "draft_close_condition": "reply", "confidence": "high", "first_seen": "2026-09-01",
            "announce": {"channel": "D1", "ts": "1788000000.000100", "at": "2026-09-03T22:24:00Z"},
            "announce_pending": False, "review_reason": None, "snooze_wake": None, "state": "open"}
    base.update(kw)
    return base


def msg(ts="1788000000.000100", *names):
    return {"ts": ts, "channel": "D1", "reactions": [{"name": n, "count": 1} for n in names]}


def run_ingest(rows, messages, records=None, today=TODAY):
    return tq.ingest_reactions(rows, messages, SLACK_CONFIG, dt.date.fromisoformat(today), NOW, records)


class ApprovalSurface(unittest.TestCase):
    def test_filter_picks_to_announce_up_to_cap_and_marks_the_rest(self):
        items = [item(origin_ts=f"2026-08-2{d}T00:00:00Z", permalink=other_permalink(d)) for d in range(5, 9)]
        meta, rows, _ = tq.filter_queue([], sweep(items=items), SLACK_CONFIG, RUN, dt.date.fromisoformat(TODAY), NOW)
        self.assertEqual(meta["surface"], "slack-self-dm")
        self.assertEqual(len(meta["to_announce"]), 2)
        self.assertEqual(meta["to_announce"], [rows[0]["key"], rows[1]["key"]])
        self.assertEqual(meta["announce_pending"], 2)
        self.assertTrue(rows[2]["announce_pending"] and rows[3]["announce_pending"])

    def test_filter_surface_none_announces_nothing(self):
        meta, rows, _ = run_filter([], sweep())
        self.assertEqual(meta["to_announce"], [])
        self.assertEqual(meta["surface"], "none")

    def test_filter_applied_keys_are_hidden_this_run(self):
        meta, rows, report = tq.filter_queue([], sweep(), CONFIG, RUN, dt.date.fromisoformat(TODAY), NOW, applied_keys=[KEY_A])
        self.assertEqual(rows, [])
        self.assertEqual(meta["applied_hidden"], 1)
        self.assertEqual(report["hidden"][0]["kind"], "applied")

    def test_announce_carried_and_already_announced_not_reannounced(self):
        prev = [row()]
        meta, rows, _ = tq.filter_queue(prev, sweep(), SLACK_CONFIG, RUN, dt.date.fromisoformat(TODAY), NOW)
        self.assertEqual(rows[0]["announce"]["ts"], "1788000000.000100")
        self.assertEqual(meta["to_announce"], [])
        self.assertEqual(meta["announced"], 1)

    def test_render_dm_has_prefix_key_and_legend(self):
        text = tq.render_dm(row(), dt.date.fromisoformat(TODAY))
        lines = text.splitlines()
        self.assertEqual(lines[0], f"[todo-loop] 候補 key={KEY_A}")
        self.assertIn("完了条件案: reply", text)
        self.assertIn(HOST_A, text)
        self.assertIn("✅ 承認", lines[-1])
        self.assertIn("7 日保留", lines[-1])

    def test_ingest_single_reactions_become_actions(self):
        rows = [row(), row(key="slack:C0A4XE8GF0F/1787227341.426700", announce={"channel": "D1", "ts": "2.0", "at": "2026-09-03T00:00:00Z"})]
        actions, nr, reverts, missing, _ = run_ingest(rows, [msg("1788000000.000100", "white_check_mark"), msg("2.0", "zzz")])
        self.assertEqual([a["kind"] for a in actions], ["approve", "snooze"])
        self.assertEqual(actions[1]["until"], "2026-09-11")
        self.assertEqual(actions[0]["announce"], "D1/1788000000.000100")
        self.assertEqual(nr, [])

    def test_ingest_never_carries_thread_key_and_reject_plain(self):
        rows = [row(thread_key="slack:C0A4XE8GF0F/1787227341.000000")]
        actions, _, _, _, _ = run_ingest(rows, [msg("1788000000.000100", "mute")])
        self.assertEqual(actions[0]["kind"], "never")
        self.assertEqual(actions[0]["thread_key"], "slack:C0A4XE8GF0F/1787227341.000000")
        actions, _, _, _, _ = run_ingest([row()], [msg("1788000000.000100", "x")])
        self.assertEqual(actions[0]["kind"], "reject")

    def test_ingest_conflict_marks_needs_review(self):
        rows = [row()]
        actions, nr, _, _, rows = run_ingest(rows, [msg("1788000000.000100", "white_check_mark", "x")])
        self.assertEqual(actions, [])
        self.assertEqual(rows[0]["state"], "needs_review")
        self.assertIn("conflicting", nr[0]["reason"])

    def test_ingest_stale_announce_marks_needs_review(self):
        rows = [row(announce={"channel": "D1", "ts": "1788000000.000100", "at": "2026-08-01T00:00:00Z"})]
        actions, nr, _, _, rows = run_ingest(rows, [msg("1788000000.000100", "white_check_mark")])
        self.assertEqual(actions, [])
        self.assertEqual(rows[0]["state"], "needs_review")
        self.assertIn("stale", nr[0]["reason"])

    def test_ingest_ignores_unknown_emoji_and_reports_missing_message(self):
        rows = [row(), row(key="slack:C0A4XE8GF0F/1787227341.426700", announce={"channel": "D1", "ts": "9.9", "at": "2026-09-03T00:00:00Z"})]
        actions, nr, _, missing, _ = run_ingest(rows, [msg("1788000000.000100", "eyes")])
        self.assertEqual(actions, [])
        self.assertEqual(nr, [])
        self.assertEqual(missing[0]["key"], "slack:C0A4XE8GF0F/1787227341.426700")

    def test_ingest_reversal_on_approved_todo_record(self):
        rec = {"id": "T1", "content": f"key={KEY_A}\nannounce=D1/1788000000.000100\n完了条件: x", "tags": ["todo"],
               "provenance": {"source_class": "tool-output"}}
        actions, _, reverts, _, _ = run_ingest([], [msg("1788000000.000100", "x")], records=[rec])
        self.assertEqual(actions, [])
        self.assertEqual(reverts[0]["current"], "approve")
        self.assertEqual(reverts[0]["reactions"], ["reject"])
        self.assertEqual(reverts[0]["source_class"], "tool-output")
        self.assertEqual(reverts[0]["key"], KEY_A)

    def test_ingest_reversal_on_reject_disposition_with_approve_reaction(self):
        rec = {"id": "D9", "content": f"todo-disposition reject key={KEY_A} written_at=2026-09-02T00:00:00Z\nannounce=D1/1788000000.000100\n理由"}
        _, _, reverts, _, _ = run_ingest([], [msg("1788000000.000100", "white_check_mark")], records=[rec])
        self.assertEqual(reverts[0]["current"], "reject")
        self.assertEqual(reverts[0]["reactions"], ["approve"])
        _, _, none, _, _ = run_ingest([], [msg("1788000000.000100", "x")], records=[rec])
        self.assertEqual(none, [])


class ApprovalSurfaceCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "todo"
        self.dir.mkdir()
        self.cfg = self.dir / "config.json"
        self.cfg.write_text(json.dumps(SLACK_CONFIG), encoding="utf-8")
        sw = self.dir / "sweep.json"
        sw.write_text(json.dumps(sweep()), encoding="utf-8")
        self.run_cli("filter", "--sweep", str(sw), "--run", RUN, "--config", str(self.cfg))

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = tq.main(["--todo-dir", str(self.dir), "--now", NOW, "--today", TODAY, *argv])
        return rc, out.getvalue(), err.getvalue()

    def test_set_announce_persists_and_drops_from_to_announce(self):
        meta, _ = tq.read_queue(self.dir / "candidates.jsonl")
        self.assertEqual(meta["to_announce"], [KEY_A])
        rc, out, err = self.run_cli("set-announce", "--key", KEY_A, "--channel", "D1", "--ts", "1788000000.000100")
        self.assertEqual(rc, 0, err)
        meta, rows = tq.read_queue(self.dir / "candidates.jsonl")
        self.assertEqual(rows[0]["announce"]["ts"], "1788000000.000100")
        self.assertEqual(meta["announced"], 1)
        self.assertEqual(meta["to_announce"], [])
        rc, _, err = self.run_cli("set-announce", "--key", "slack:C0/0.0", "--channel", "D1", "--ts", "1.0")
        self.assertEqual(rc, 3)

    def test_render_dm_cli(self):
        rc, out, _ = self.run_cli("render-dm", "--key", KEY_A, "--config", str(self.cfg))
        self.assertEqual(rc, 0)
        self.assertTrue(out.startswith(f"[todo-loop] 候補 key={KEY_A}"))

    def test_ingest_reactions_cli_writes_needs_review_and_lists_applied_keys(self):
        self.run_cli("set-announce", "--key", KEY_A, "--channel", "D1", "--ts", "1788000000.000100")
        r = self.dir / "reactions.json"
        r.write_text(json.dumps({"messages": [msg("1788000000.000100", "white_check_mark")]}), encoding="utf-8")
        rc, out, err = self.run_cli("ingest-reactions", "--reactions", str(r), "--run", RUN, "--config", str(self.cfg))
        self.assertEqual(rc, 0, err)
        res = json.loads(out)
        self.assertEqual(res["applied_keys"], [KEY_A])
        self.assertEqual(res["actions"][0]["kind"], "approve")
        r.write_text(json.dumps({"messages": [msg("1788000000.000100", "white_check_mark", "x")]}), encoding="utf-8")
        rc, out, _ = self.run_cli("ingest-reactions", "--reactions", str(r), "--run", RUN, "--config", str(self.cfg))
        _, rows = tq.read_queue(self.dir / "candidates.jsonl")
        self.assertEqual(rows[0]["state"], "needs_review")
        applied = self.dir / "applied.json"
        applied.write_text(json.dumps({"keys": [KEY_A]}), encoding="utf-8")
        rc, out, _ = self.run_cli("filter", "--sweep", str(self.dir / "sweep.json"), "--run", RUN, "--config", str(self.cfg), "--applied", str(applied))
        self.assertEqual(json.loads(out)["applied_hidden"], 1)


CANVAS_CONFIG = {
    "queue": {"ttl_days": 21, "snooze_days": 7},
    "surfaces": {
        "queue_surface": "slack-self-dm",
        "channel": "D1",
        "canvas": "auto",
        "schedule_label": "毎日 07:23 JST",
        "reactions": {"approve": "white_check_mark", "reject": "x", "snooze": "zzz", "never": "mute"},
    },
    "sources": [{"name": "work-slack-saved", "class": "inferred", "max_age_days": 30}],
}


def canvas_row(key=KEY_A, **kw):
    r = {
        "type": "candidate",
        "key": key,
        "source": "work-slack-saved",
        "class": "inferred",
        "state": "open",
        "title": "返信する | 件",
        "permalink": HOST_A,
        "origin_ts": "2026-08-28T09:55:10+09:00",
        "due": "2026-09-10",
        "first_seen": "2026-09-01",
        "announce": {"channel": "D1", "ts": "1788000000.000100", "at": NOW},
    }
    r.update(kw)
    return r


def canvas_meta(**kw):
    m = {
        "type": "meta",
        "schema": 1,
        "run": RUN,
        "generated_at": NOW,
        "today": TODAY,
        "open": 1,
        "needs_review": 0,
        "filters_skipped": [],
        "sources": [
            {"name": "work-slack-saved", "status": "swept", "count": 3},
            {"name": "work-google-tasks", "status": "unswept", "reason": "gws 401"},
        ],
        "dispositions_enum": {"state": "complete", "total": 38, "returned": 38, "remaining": 0, "reason": ""},
        "todos_enum": {"state": "complete", "total": 40, "returned": 40, "remaining": 0, "reason": ""},
    }
    m.update(kw)
    return m


class CanvasView(unittest.TestCase):
    def summary(self, **kw):
        s = {"queue": None, "sources": [], "stores": None, "prs": None, "loops": {"todo-collect": {"last": NOW, "hours_ago": 1.2}}, "stale": []}
        s.update(kw)
        return s

    def render(self, rows=None, meta=None, summary=None, exclude=(), config=CANVAS_CONFIG):
        return tq.render_canvas(
            canvas_meta() if meta is None else meta,
            [canvas_row()] if rows is None else rows,
            summary or self.summary(),
            config,
            dt.date.fromisoformat(TODAY),
            exclude=exclude,
        )

    def test_five_sections_with_fixed_heading_prefixes_and_no_deep_headings(self):
        secs = self.render()
        self.assertEqual([s["n"] for s in secs], [1, 2, 3, 4, 5])
        for s, h in zip(secs, tq.CANVAS_HEADINGS):
            self.assertTrue(s["heading"].startswith(h))
            self.assertTrue(s["markdown"].startswith(f"# {h}"))
        self.assertNotRegex(tq.canvas_markdown(secs), r"(?m)^#{4,} ")

    def test_status_section_shows_last_run_schedule_unswept_and_enums(self):
        md = self.render()[0]["markdown"]
        self.assertIn("2026-09-05 07:24 JST", md)
        self.assertIn("次回: 毎日 07:23 JST", md)
        self.assertIn("work-google-tasks（gws 401）", md)
        self.assertIn("dispositions complete 38 件 / todos complete 40 件", md)
        self.assertIn("30 時間超 = 停止中", md)
        self.assertNotIn(":red_circle:", md)

    def test_status_section_flags_a_stale_loop_and_skipped_filters(self):
        stale = self.summary(loops={"todo-collect": {"last": "2026-09-02T22:00:00Z", "hours_ago": 48.4}}, stale=["todo-collect"])
        md = self.render(summary=stale, meta=canvas_meta(filters_skipped=["disposition", "snooze"]))[0]["markdown"]
        self.assertIn(":red_circle: **停止中**", md)
        self.assertIn("48.4h", md)
        self.assertIn("disposition フィルタ未適用（disposition, snooze）", md)

    def test_pending_table_links_dm_and_source_and_escapes_pipes(self):
        sec = self.render()[1]
        self.assertIn("（1 件）", sec["heading"])
        self.assertIn("[DM](https://mercari.slack.com/archives/D1/p1788000000000100)", sec["markdown"])
        self.assertIn(f"[元]({HOST_A})", sec["markdown"])
        self.assertIn("返信する ／ 件", sec["markdown"])
        self.assertIn("| 2026-09-10 | 7 |", sec["markdown"])

    def test_pending_table_marks_needs_review_and_pending_announce(self):
        rows = [
            canvas_row(),
            canvas_row(key="slack:C0A4XE8GF0F/1.000002", state="needs_review", title="b"),
            canvas_row(key="slack:C0A4XE8GF0F/1.000003", announce=None, announce_pending=True, title="c"),
        ]
        sec = self.render(rows=rows)[1]
        self.assertIn("（3 件、要確認 1 件）", sec["heading"])
        self.assertIn(":warning: b（要確認）", sec["markdown"])
        self.assertIn("未送信（翌 run）", sec["markdown"])

    def test_exclude_hides_keys_and_empty_queue_says_so(self):
        sec = self.render(exclude=[KEY_A])[1]
        self.assertIn("（0 件）", sec["heading"])
        self.assertIn("承認待ちはありません", sec["markdown"])
        self.assertIn("処置済み 1 件を除いた", sec["markdown"])
        sec = self.render(rows=[])[1]
        self.assertIn("承認待ちはありません", sec["markdown"])
        self.assertNotIn("処置済み", sec["markdown"])

    def test_slack_host_comes_from_config_then_permalink_then_default(self):
        cfg = json.loads(json.dumps(CANVAS_CONFIG))
        cfg["surfaces"]["slack_host"] = "x.slack.com"
        self.assertIn("https://x.slack.com/archives/D1/", self.render(config=cfg)[1]["markdown"])
        self.assertEqual(tq.slack_host_for([{"permalink": HOST_B}], CANVAS_CONFIG), "mercari.enterprise.slack.com")
        self.assertEqual(tq.slack_host_for([{"permalink": None}], CANVAS_CONFIG), "slack.com")

    def test_stores_table_fills_exactly_one_three_valued_column_per_store(self):
        stores = {
            "written_at": NOW,
            "run": RUN,
            "air_pending_forget": 8,
            "stores": {
                "memory-work": {"state": "complete", "open": 12},
                "empty": {"state": "complete", "open": 0},
                "ai-memory": {"state": "unreached", "reason": "MCP 未登録"},
                "big": {"state": "truncated", "remaining": "unknown"},
            },
        }
        md = self.render(summary=self.summary(stores=stores))[2]["markdown"]
        self.assertIn("| store | 列挙完了 N | 0 件 | 未列挙（理由） | truncated 残数 |", md)
        self.assertIn("| memory-work | 12 |  |  |  |", md)
        self.assertIn("| empty |  | 0 |  |  |", md)
        self.assertIn("| ai-memory |  |  | MCP 未登録 |  |", md)
        self.assertIn("| big |  |  |  | unknown |", md)
        self.assertIn("air 待ち forget: 8 件", md)
        self.assertIn("データなし", self.render()[2]["markdown"])

    def test_prs_section_renders_fetch_failure_empty_and_rows(self):
        base = {"written_at": NOW, "run": RUN}
        md = self.render(summary=self.summary(prs={**base, "prs": None, "error": "gh: 504"}))[3]["markdown"]
        self.assertIn("取得失敗（gh: 504）", md)
        md = self.render(summary=self.summary(prs={**base, "prs": []}))[3]["markdown"]
        self.assertIn("待ち PR なし", md)
        pr = {
            "repo": "kouzoh/zp-SHIN",
            "number": 179,
            "mergeStateStatus": "CLEAN",
            "createdAt": "2026-08-30T00:00:00Z",
            "url": "https://github.com/kouzoh/zp-SHIN/pull/179",
        }
        md = self.render(summary=self.summary(prs={**base, "prs": [pr]}))[3]["markdown"]
        self.assertIn(
            "| [kouzoh/zp-SHIN#179](https://github.com/kouzoh/zp-SHIN/pull/179) | CLEAN | 5 | `gh -R kouzoh/zp-SHIN pr merge 179 --merge --delete-branch` |",
            md,
        )
        self.assertIn("データなし", self.render()[3]["markdown"])

    def test_usage_section_uses_configured_reaction_names_and_snooze_days(self):
        md = self.render()[4]["markdown"]
        self.assertIn(":white_check_mark: 承認 / :x: 却下 / :zzz: 7 日 snooze / :mute:", md)
        self.assertIn("`/todo-approve`", md)


class CanvasCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "todo"
        self.dir.mkdir()
        self.cfg = self.dir / "config.json"
        self.cfg.write_text(json.dumps(CANVAS_CONFIG), encoding="utf-8")
        sw = self.dir / "sweep.json"
        sw.write_text(json.dumps(sweep()), encoding="utf-8")
        self.run_cli("filter", "--sweep", str(sw), "--run", RUN, "--config", str(self.cfg))

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = tq.main(["--todo-dir", str(self.dir), "--now", NOW, "--today", TODAY, *argv])
        return rc, out.getvalue(), err.getvalue()

    def test_render_canvas_json_and_section_filter_leave_the_queue_alone(self):
        rc, out, err = self.run_cli("render-canvas", "--json", "--config", str(self.cfg))
        self.assertEqual(rc, 0, err)
        doc = json.loads(out)
        self.assertEqual(doc["title"], tq.CANVAS_TITLE)
        self.assertIsNone(doc["canvas"])
        self.assertEqual([s["n"] for s in doc["sections"]], [1, 2, 3, 4, 5])
        self.assertEqual(doc["open"], 1)
        rc, out, _ = self.run_cli("render-canvas", "--section", "2", "--config", str(self.cfg), "--exclude", KEY_A)
        self.assertTrue(out.startswith("# 2. 承認待ち（0 件）"), out)
        self.assertNotIn("# 1. 状態", out)
        _, rows = tq.read_queue(self.dir / "candidates.jsonl")
        self.assertEqual(len(rows), 1)

    def test_render_canvas_without_queue_file_still_renders(self):
        rc, out, err = self.run_cli("render-canvas", "--queue", str(self.dir / "absent.jsonl"), "--config", str(self.cfg))
        self.assertEqual(rc, 0, err)
        self.assertIn("データなし（`candidates.jsonl` 不在", out)

    def test_set_canvas_records_create_then_update_then_clear(self):
        rc, out, err = self.run_cli("set-canvas", "--id", "F1", "--url", "https://x.slack.com/docs/T1/F1", "--run", RUN)
        self.assertEqual(rc, 0, err)
        doc = json.loads((self.dir / "surfaces.json").read_text(encoding="utf-8"))
        self.assertEqual((doc["canvas"]["id"], doc["canvas"]["created_at"], doc["canvas"]["last_run"], doc["canvas"]["updates"]), ("F1", NOW, RUN, 1))
        rc, out, _ = self.run_cli("set-canvas", "--id", "F1", "--url", "https://x.slack.com/docs/T1/F1")
        doc = json.loads(out)
        self.assertEqual((doc["canvas"]["updates"], doc["canvas"]["last_run"], doc["canvas"]["created_at"]), (2, RUN, NOW))
        rc, out, _ = self.run_cli("set-canvas", "--id", "F2", "--url", "https://x.slack.com/docs/T1/F2", "--run", "R2")
        doc = json.loads(out)
        self.assertEqual((doc["canvas"]["updates"], doc["canvas"]["last_run"]), (1, "R2"))
        rc, out, _ = self.run_cli("render-canvas", "--json", "--config", str(self.cfg))
        self.assertEqual(json.loads(out)["canvas"]["id"], "F2")
        rc, out, _ = self.run_cli("set-canvas", "--clear")
        self.assertIsNone(json.loads(out)["canvas"])
        rc, _, err = self.run_cli("set-canvas", "--id", "F3")
        self.assertEqual(rc, 3)

    def test_set_store_upserts_one_store_and_validates_the_enum(self):
        seed = {
            "written_at": "2026-08-30T23:20:00Z",
            "run": "R0",
            "air_pending_forget": 8,
            "stores": {"ai-memory": {"state": "unreached", "reason": "MCP 未登録"}},
        }
        (self.dir / "stores.json").write_text(json.dumps(seed), encoding="utf-8")
        rc, out, err = self.run_cli("set-store", "--name", "memory-work", "--state", "complete", "--open", "12", "--run", RUN)
        self.assertEqual(rc, 0, err)
        doc = json.loads((self.dir / "stores.json").read_text(encoding="utf-8"))
        self.assertEqual(doc["stores"]["memory-work"]["open"], 12)
        self.assertEqual(doc["stores"]["ai-memory"]["reason"], "MCP 未登録")
        self.assertEqual((doc["air_pending_forget"], doc["run"], doc["written_at"]), (8, RUN, NOW))
        rc, _, err = self.run_cli("set-store", "--name", "x", "--state", "truncated")
        self.assertEqual(rc, 3)
        self.assertIn("--remaining", err)
        rc, _, err = self.run_cli("set-store", "--name", "x", "--state", "unreached")
        self.assertEqual(rc, 3)
        rc, _, err = self.run_cli("set-store", "--air-pending", "3")
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads((self.dir / "stores.json").read_text(encoding="utf-8"))["air_pending_forget"], 3)
        rc, out, _ = self.run_cli("render-canvas", "--section", "3", "--config", str(self.cfg))
        self.assertIn("| memory-work | 12 |  |  |  |", out)
        self.assertIn("air 待ち forget: 3 件", out)


class LiveFixes(unittest.TestCase):
    """Regressions from the first live run of all three phases (2026-09-04)."""

    def test_dedup_matches_legacy_todo_by_permalink_without_key_line(self):
        legacy = {"id": "L1", "content": f"NASA レビュー\nprovenance: {HOST_B}", "tags": ["todo"]}
        self.assertEqual(tq.existing_todo_keys([legacy]), {KEY_A})
        meta, rows, report = run_filter([], sweep(todos=env(records=[legacy])))
        self.assertEqual(rows, [])
        self.assertEqual(report["deduped_keys"], [KEY_A])

    def test_render_dm_separates_url_line_from_legend_with_a_blank_line(self):
        lines = tq.render_dm(row(), dt.date.fromisoformat(TODAY)).splitlines()
        i = next(n for n, l in enumerate(lines) if l.startswith("元: "))
        self.assertEqual(lines[i + 1], "")
        self.assertIn("✅ 承認", lines[i + 2])

    def test_canvas_status_age_comes_from_generated_at_not_last_ok_run(self):
        now_dt = dt.datetime.fromisoformat("2026-09-04T22:30:00+00:00")
        today = dt.date.fromisoformat(TODAY)
        summary = {
            "queue": None,
            "sources": [],
            "stores": None,
            "prs": None,
            "loops": {"todo-collect": {"last": "2026-09-03T22:33:04Z", "hours_ago": 24.0}},
            "stale": [],
        }
        md = tq.render_canvas(canvas_meta(), [canvas_row()], summary, CANVAS_CONFIG, today, now_dt=now_dt)[0]["markdown"]
        self.assertIn("0.1h 前", md)
        self.assertNotIn("24.0h", md)
        summary["stale"] = ["todo-collect"]
        md = tq.render_canvas(canvas_meta(), [canvas_row()], summary, CANVAS_CONFIG, today, now_dt=now_dt)[0]["markdown"]
        self.assertNotIn(":red_circle:", md)
        old = canvas_meta(generated_at="2026-09-02T00:00:00Z")
        md = tq.render_canvas(old, [canvas_row()], summary, CANVAS_CONFIG, today, now_dt=now_dt)[0]["markdown"]
        self.assertIn(":red_circle:", md)


class DispositionParseShapes(unittest.TestCase):
    """The shape the first live run (2026-09-04) actually wrote: key= first, the
    todo-disposition line fourth, until= / thread_key= as standalone lines."""

    LIVE_SNOOZE = {
        "id": "S1",
        "content": (
            "key=slack:GGX3VLZ7E/1787900164.182469\nannounce=D06EA7KEM5E/1788526481.113429\nuntil=2026-09-11\n"
            "todo-disposition snooze key=slack:GGX3VLZ7E/1787900164.182469 written_at=2026-09-04T13:23:25Z reason=reaction(zzz)\n"
            "業務委託 — 2026-09-11 まで保留"
        ),
    }
    LIVE_NEVER = {
        "id": "N1",
        "content": (
            "key=slack:GN1AZLYPP/1786002615.684859\nannounce=D06EA7KEM5E/1788526428.850359\nthread_key=slack:GN1AZLYPP/1786002615.684859\n"
            "todo-disposition never key=slack:GN1AZLYPP/1786002615.684859 written_at=2026-09-04T13:23:25Z reason=reaction(mute)\n派遣社員"
        ),
    }

    def test_disposition_line_is_found_anywhere_and_fields_from_standalone_lines(self):
        d = tq.parse_disposition(self.LIVE_SNOOZE)
        self.assertEqual(
            (d["kind"], d["key"], d["until"], d["announce"]),
            ("snooze", "slack:GGX3VLZ7E/1787900164.182469", "2026-09-11", "D06EA7KEM5E/1788526481.113429"),
        )
        d = tq.parse_disposition(self.LIVE_NEVER)
        self.assertEqual((d["kind"], d["thread_key"], d["written_at"]), ("never", "slack:GN1AZLYPP/1786002615.684859", "2026-09-04T13:23:25Z"))

    def test_canonical_first_line_shape_still_parses_and_the_disposition_line_wins(self):
        d = tq.parse_disposition(disp("snooze", KEY_A, until="2026-09-20"))
        self.assertEqual((d["kind"], d["until"]), ("snooze", "2026-09-20"))
        both = {"id": "B", "content": f"until=2026-09-01\ntodo-disposition snooze key={KEY_A} written_at=2026-09-04T00:00:00Z until=2026-09-20"}
        self.assertEqual(tq.parse_disposition(both)["until"], "2026-09-20")
        self.assertIsNone(tq.parse_disposition({"id": "T", "content": f"key={KEY_A}\n完了条件: x"}))

    def test_live_shaped_records_hide_their_candidates_in_filter(self):
        items = [
            item(title="業務委託", permalink="https://mercari.enterprise.slack.com/archives/GGX3VLZ7E/p1787900164182469", origin_ts="2026-08-28T09:00:00+09:00"),
            item(title="派遣社員", permalink="https://mercari.enterprise.slack.com/archives/GN1AZLYPP/p1786002615684859", origin_ts="2026-08-06T09:00:00+09:00"),
        ]
        doc = sweep(items=items, dispositions=env(records=[self.LIVE_SNOOZE, self.LIVE_NEVER]))
        meta, rows, report = tq.filter_queue([], doc, CONFIG, RUN, dt.date(2026, 9, 5), NOW)
        self.assertEqual(rows, [])
        self.assertEqual(sorted(h["kind"] for h in report["hidden"]), ["never", "snooze"])


if __name__ == "__main__":
    unittest.main()
