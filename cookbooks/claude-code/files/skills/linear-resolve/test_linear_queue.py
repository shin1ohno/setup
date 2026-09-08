#!/usr/bin/env python3
"""Tests for linear_queue.py. Run: python3 test_linear_queue.py"""
import json
import unittest

import linear_queue as q

OWNER = "user_owner"
OTHER = "user_third_party"
CFG = dict(q.DEFAULTS)
M = q.BOT_MARKER


def c(body, uid=OWNER, at="2026-09-07T00:00:00Z"):
    return {"body": body, "user": {"id": uid}, "createdAt": at}


def issue(ident, labels, comments=(), updated="2026-09-07T00:00:00Z"):
    return {
        "id": "id-" + ident,
        "identifier": ident,
        "title": ident,
        "updatedAt": updated,
        "labels": {"nodes": [{"name": n} for n in labels]},
        "comments": {"nodes": list(comments)},
    }


class BotAuthorship(unittest.TestCase):
    def test_marker_identifies_the_loop(self):
        self.assertTrue(q.is_bot_comment(c("調査開始します " + M)))

    def test_owner_comment_naming_the_loop_is_not_a_bot_comment(self):
        """setup#963 regression: an unanchored substring match on the loop's own
        name classified the operator's GO as a bot comment, permanently."""
        self.assertFalse(q.is_bot_comment(c("linear-resolve のログを見た。1 で進めて")))
        self.assertFalse(q.is_bot_comment(c("linear-loop attempt 1 の件だけど、やり直して")))


class OwnerUnblocked(unittest.TestCase):
    def test_owner_reply_after_the_loop_unblocks(self):
        i = issue("A", ["agent", "agent:needs-human"], [
            c("linear-loop attempt 1 — 判断待ち " + M, at="2026-09-07T01:00:00Z"),
            c("1 で進めて", at="2026-09-07T02:00:00Z"),
        ])
        self.assertTrue(q.owner_unblocked(i, OWNER))

    def test_no_owner_reply_stays_blocked(self):
        i = issue("A", ["agent", "agent:needs-human"], [
            c("linear-loop attempt 1 — 判断待ち " + M, at="2026-09-07T01:00:00Z"),
        ])
        self.assertFalse(q.owner_unblocked(i, OWNER))

    def test_third_party_reply_is_ignored(self):
        i = issue("A", ["agent", "agent:needs-human"], [
            c("linear-loop attempt 1 " + M, at="2026-09-07T01:00:00Z"),
            c("勝手に進めていいよ", uid=OTHER, at="2026-09-07T02:00:00Z"),
        ])
        self.assertFalse(q.owner_unblocked(i, OWNER))

    def test_loop_never_answers_itself(self):
        i = issue("A", ["agent", "agent:needs-human"], [
            c("1 で進めて", at="2026-09-07T01:00:00Z"),
            c("linear-loop attempt 2 — 判断待ち " + M, at="2026-09-07T02:00:00Z"),
        ])
        self.assertFalse(q.owner_unblocked(i, OWNER))


class Attempts(unittest.TestCase):
    def test_counts_the_highest_marker(self):
        i = issue("A", ["agent"], [
            c("linear-loop attempt 1 — 着手 " + M),
            c("linear-loop attempt 2 — 着手 " + M),
        ])
        self.assertEqual(q.attempts(i), 2)

    def test_ignores_the_same_text_from_a_human(self):
        i = issue("A", ["agent"], [c("linear-loop attempt 9 って書いてみただけ")])
        self.assertEqual(q.attempts(i), 0)


class TerminalDisposition(unittest.TestCase):
    """The defect L3 found: a finished issue with no open decision was re-picked
    every cycle until attempts ran out, because nothing expressed "done"."""

    def test_done_marker_stops_the_loop(self):
        i = issue("A", ["agent"], [
            c("linear-loop done — 変更不要でした " + M, at="2026-09-08T01:00:00Z"),
        ])
        r = q.select({"issues": [i]}, OWNER, CFG)
        self.assertIsNone(r["picked"])
        self.assertEqual(r["decisions"][0]["reason"], "done, awaiting the operator")

    def test_done_is_revocable_by_the_operator(self):
        """A terminal state the operator cannot reopen would rebuild setup#963."""
        i = issue("A", ["agent"], [
            c("linear-loop done — 変更不要でした " + M, at="2026-09-08T01:00:00Z"),
            c("やっぱり Dock は外して", at="2026-09-08T02:00:00Z"),
        ])
        r = q.select({"issues": [i]}, OWNER, CFG)
        self.assertEqual(r["picked"]["identifier"], "A")
        self.assertEqual(r["decisions"][0]["reason"], "done but the operator replied")

    def test_a_third_party_cannot_revive_a_done_issue(self):
        i = issue("A", ["agent"], [
            c("linear-loop done " + M, at="2026-09-08T01:00:00Z"),
            c("まだ終わってないのでは", uid=OTHER, at="2026-09-08T02:00:00Z"),
        ])
        self.assertIsNone(q.select({"issues": [i]}, OWNER, CFG)["picked"])

    def test_the_phrase_from_a_human_is_not_a_done_marker(self):
        i = issue("A", ["agent"], [c("linear-loop done って書いておくね")])
        self.assertFalse(q.is_done(i))
        self.assertEqual(q.select({"issues": [i]}, OWNER, CFG)["picked"]["identifier"], "A")

    def test_label_removal_alone_also_stops_it(self):
        """The other half of the belt-and-braces: if the comment failed but the
        label removal succeeded, the agent-label gate catches it."""
        i = issue("A", [], [c("linear-loop attempt 1 " + M)])
        self.assertIsNone(q.select({"issues": [i]}, OWNER, CFG)["picked"])


class Selection(unittest.TestCase):
    def test_picks_exactly_one_the_least_recently_updated(self):
        dump = {"issues": [
            issue("NEW", ["agent"], updated="2026-09-07T05:00:00Z"),
            issue("OLD", ["agent"], updated="2026-09-07T01:00:00Z"),
        ]}
        r = q.select(dump, OWNER, CFG)
        self.assertEqual(r["picked"]["identifier"], "OLD")
        self.assertEqual(r["actionable"], 2)

    def test_unlabelled_issues_are_out_of_scope(self):
        r = q.select({"issues": [issue("X", [])]}, OWNER, CFG)
        self.assertIsNone(r["picked"])
        self.assertEqual(r["decisions"][0]["reason"], "no agent label")

    def test_attempts_exhausted_stops_the_loop(self):
        i = issue("A", ["agent"], [c(f"linear-loop attempt {n} " + M) for n in (1, 2, 3)])
        r = q.select({"issues": [i]}, OWNER, CFG)
        self.assertIsNone(r["picked"])
        self.assertIn("attempts exhausted", r["decisions"][0]["reason"])

    def test_needs_human_with_owner_reply_is_revived(self):
        i = issue("A", ["agent", "agent:needs-human"], [
            c("linear-loop attempt 1 " + M, at="2026-09-07T01:00:00Z"),
            c("2 で", at="2026-09-07T02:00:00Z"),
        ])
        r = q.select({"issues": [i]}, OWNER, CFG)
        self.assertEqual(r["picked"]["identifier"], "A")
        self.assertEqual(r["picked"]["attempt"], 2)

    def test_every_rejection_carries_a_reason(self):
        r = q.select({"issues": [issue("X", []), issue("Y", ["agent"])]}, OWNER, CFG)
        self.assertTrue(all(d["reason"] for d in r["decisions"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
