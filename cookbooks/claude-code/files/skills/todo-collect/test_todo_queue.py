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


if __name__ == "__main__":
    unittest.main()
