"""Tests for slop_scan.py. Repo-only: the cookbook does not deploy test_*.py.

Run: python3 -m unittest discover -s <this dir> -p 'test_*.py' -v
"""

import glob
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import slop_scan  # noqa: E402

SCRIPT = os.path.join(HERE, "slop_scan.py")
FIXTURES = os.path.normpath(os.path.join(HERE, "..", "references", "fixtures"))

# Positive / negative controls taken from the pathology-2 example in the
# algoartis Zenn article (same text as yomiyasu articles/yomiyasu-ai-writing-lint.md).
ARTICLE_POSITIVE = "保守性担保機能の形骸化の防止。"
ARTICLE_NEGATIVE = "コードの保守性を保つ仕組みが形骸化しないように、定期的なレビューを実施します。"


def rules(result, pathology=None):
    return [f["rule"] for f in result["findings"]
            if pathology is None or f["pathology"] == pathology]


def run_cli(text, *extra):
    return subprocess.run([sys.executable, "-B", SCRIPT, "-"] + list(extra),
                          input=text, capture_output=True, text=True)


class NominalChainTest(unittest.TestCase):
    def test_article_example_is_detected(self):
        r = slop_scan.scan(ARTICLE_POSITIVE, use_vendor=False)
        hits = [f for f in r["findings"] if f["rule"] == "nominal_chain"]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["snippet"], "保守性担保機能の形骸化の防止")
        self.assertEqual(hits[0]["pathology"], "2")

    def test_article_rewrite_is_not_detected(self):
        r = slop_scan.scan(ARTICLE_NEGATIVE, use_vendor=False)
        self.assertNotIn("nominal_chain", rules(r))
        self.assertEqual(r["by_pathology"]["2"], 0)

    def test_two_nouns_are_not_a_chain(self):
        r = slop_scan.scan("設定の変更を反映する。", use_vendor=False)
        self.assertNotIn("nominal_chain", rules(r))

    def test_code_and_tables_are_skipped(self):
        text = "```\n保守性担保機能の形骸化の防止\n```\n\n| 保守性担保機能の形骸化の防止 |\n"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("nominal_chain", rules(r))


class TaigenRunTest(unittest.TestCase):
    def test_three_noun_endings_in_prose(self):
        text = "障害対応の迅速化。監視体制の強化。運用負荷の軽減。"
        r = slop_scan.scan(text, use_vendor=False)
        hits = [f for f in r["findings"] if f["rule"] == "taigen_run"]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["line"], 1)

    def test_two_noun_endings_are_fine(self):
        text = "障害対応の迅速化。監視体制の強化。運用負荷は下がった。"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("taigen_run", rules(r))

    def test_list_items_do_not_count(self):
        text = "- 障害対応の迅速化\n- 監視体制の強化\n- 運用負荷の軽減\n"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("taigen_run", rules(r))

    def test_heading_breaks_the_run(self):
        text = "障害対応の迅速化。監視体制の強化。\n\n## 次\n\n運用負荷の軽減。"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("taigen_run", rules(r))


class HalfwidthTest(unittest.TestCase):
    def test_vendor_halfwidth_rule_is_removed(self):
        # This line trips the vendor's unnatural_halfwidth_space rule.
        text = "この README は yomiyasu で生成した。\n"
        raw, ok = slop_scan.run_vendor(text)
        self.assertTrue(ok)
        self.assertIn("unnatural_halfwidth_space", [f["rule"] for f in raw])
        r = slop_scan.scan(text)
        self.assertNotIn("unnatural_halfwidth_space", rules(r))
        self.assertNotIn("unnatural_halfwidth_space", r["dropped_rules"])
        self.assertNotIn("unnatural_halfwidth_space", json.dumps(r))

    def test_consistent_spacing_is_not_reported(self):
        r = slop_scan.scan("この README は yomiyasu で生成した。API を叩く。", use_vendor=False)
        self.assertNotIn("halfwidth_mixed", rules(r))

    def test_mixed_spacing_is_reported(self):
        r = slop_scan.scan("この README は生成物。APIを叩く。", use_vendor=False)
        self.assertIn("halfwidth_mixed", rules(r))


class VendorFilterTest(unittest.TestCase):
    def test_kept_and_dropped_rules(self):
        kept, unknown = slop_scan.filter_vendor([
            {"rule": "metaphor_verb", "line": 1, "snippet": "a", "message": "m"},
            {"rule": "trailing_colon", "line": 2, "snippet": "b", "message": "m"},
            {"rule": "excess_bold", "line": 1, "snippet": "c", "message": "m"},
            {"rule": "renamed_upstream_rule", "line": 3, "snippet": "d", "message": "m"},
        ])
        self.assertEqual([(k["rule"], k["pathology"]) for k in kept],
                         [("metaphor_verb", "1"), ("excess_bold", "3")])
        self.assertEqual(unknown, ["renamed_upstream_rule"])

    def test_metaphor_verb_maps_to_pathology_1(self):
        r = slop_scan.scan("設定の確認で毎朝の時間を溶かしている。\n")
        self.assertTrue(r["vendor_ok"])
        self.assertIn("metaphor_verb", rules(r, "1"))

    def test_negative_parallelism_maps_to_pathology_3(self):
        r = slop_scan.scan("これは単なるツールではなく、チームの考え方そのものだ。\n")
        self.assertIn("negative_parallelism", rules(r, "3"))

    def test_vendor_failure_keeps_own_detectors(self):
        orig = slop_scan.VENDOR_LINT
        try:
            slop_scan.VENDOR_LINT = os.path.join(HERE, "vendor", "does-not-exist.py")
            r = slop_scan.scan(ARTICLE_POSITIVE)
        finally:
            slop_scan.VENDOR_LINT = orig
        self.assertFalse(r["vendor_ok"])
        self.assertIn("nominal_chain", rules(r))


class CliTest(unittest.TestCase):
    def test_exit_zero_and_json_shape(self):
        proc = run_cli(ARTICLE_POSITIVE + "\n", "--json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(set(data), {"findings", "by_pathology", "dropped_rules", "vendor_ok"})
        self.assertEqual(set(data["by_pathology"]), {"1", "2", "3", "other"})
        for f in data["findings"]:
            self.assertEqual(set(f), {"rule", "pathology", "line", "snippet", "message"})

    def test_exit_zero_on_missing_file(self):
        proc = subprocess.run([sys.executable, "-B", SCRIPT, "/nonexistent/x.md"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0)


class InanimateAgencyTest(unittest.TestCase):
    def test_review_repro_is_pathology_1(self):
        r = slop_scan.scan("この施策が成長を加速させる。データが物語る。", use_vendor=False)
        hits = [f["snippet"] for f in r["findings"] if f["rule"] == "inanimate_agency"]
        self.assertEqual(hits, ["施策が成長を加速させ", "データが物語る"])
        self.assertEqual(r["by_pathology"]["1"], 2)

    def test_person_and_organisation_subjects_are_skipped(self):
        for text in ("チームが成長を支える。", "担当者が改善を後押しした。",
                     "会社が新しい市場を生み出した。", "ユーザーは不満を語った。"):
            with self.subTest(text=text):
                r = slop_scan.scan(text, use_vendor=False)
                self.assertNotIn("inanimate_agency", rules(r))

    def test_verb_inside_another_word_is_skipped(self):
        for text in ("担当は催促した。", "設定は深呼吸するほど長い。"):
            with self.subTest(text=text):
                r = slop_scan.scan(text, use_vendor=False)
                self.assertNotIn("inanimate_agency", rules(r))

    def test_text_report_states_limited_coverage(self):
        proc = run_cli("本文。\n")
        self.assertIn("0 件でも病理①がないとは限らない", proc.stdout)


class ClassifyLinesTest(unittest.TestCase):
    def kinds(self, text):
        return [(no, kind) for no, kind, _ in slop_scan.classify_lines(text)]

    def test_longer_fence_is_not_closed_by_shorter_one(self):
        text = "````\n```\n保守性担保機能の形骸化の防止\n```\n````\n"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("nominal_chain", rules(r))

    def test_backtick_fence_is_not_closed_by_tilde(self):
        text = "```\n~~~\n保守性担保機能の形骸化の防止\n```\n"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("nominal_chain", rules(r))

    def test_indented_code_after_blank_line_is_code(self):
        text = "本文です。\n\n    保守性担保機能の形骸化の防止\n    課題。問題。結論。\n"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("nominal_chain", rules(r))
        self.assertNotIn("taigen_run", rules(r))

    def test_indented_list_continuation_is_prose(self):
        text = "- 項目\n\n    保守性担保機能の形骸化の防止。\n"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertIn("nominal_chain", rules(r))

    def test_prose_after_inline_comment_is_scanned(self):
        r = slop_scan.scan("<!-- note --> 課題。問題。結論。\n", use_vendor=False)
        self.assertIn("taigen_run", rules(r))

    def test_prose_after_multiline_comment_close_is_scanned(self):
        r = slop_scan.scan("<!--\nnote\n--> 課題。問題。結論。\n", use_vendor=False)
        self.assertIn("taigen_run", rules(r))

    def test_unclosed_front_matter_keys_are_not_prose(self):
        text = "---\ntitle: 障害対応\ntags: 監視\nowner: 運用\n\n本文は動詞で終わる。\n"
        r = slop_scan.scan(text, use_vendor=False)
        self.assertNotIn("taigen_run", rules(r))
        self.assertEqual(self.kinds(text)[:4], [(1, "other"), (2, "other"), (3, "other"), (4, "other")])


class VendorRobustnessTest(unittest.TestCase):
    def with_stub(self, body):
        orig = slop_scan.VENDOR_LINT
        with tempfile.TemporaryDirectory() as d:
            stub = os.path.join(d, "stub.py")
            with open(stub, "w", encoding="utf-8") as f:
                f.write(body)
            try:
                slop_scan.VENDOR_LINT = stub
                return slop_scan.scan(ARTICLE_POSITIVE)
            finally:
                slop_scan.VENDOR_LINT = orig

    def test_vendor_findings_in_comments_are_dropped(self):
        text = "<!--\n設計に踏み込んだ議論をする。データが静かに壊れる。\n-->\n本文。\n"
        raw, ok = slop_scan.run_vendor(text)
        self.assertTrue(ok)
        self.assertIn(2, [f["line"] for f in raw])
        r = slop_scan.scan(text)
        self.assertEqual([f for f in r["findings"] if f["line"] == 2], [])

    def test_unexpected_json_shape_is_vendor_failure(self):
        r = self.with_stub("print('[1,2]')\n")
        self.assertFalse(r["vendor_ok"])
        self.assertIn("nominal_chain", rules(r))

    def test_non_dict_findings_are_skipped(self):
        r = self.with_stub(
            "import json\nprint(json.dumps({'findings': ['x', 3, {'rule': ['a']},"
            " {'rule': 'excess_bold', 'line': 'L1'}]}))\n")
        self.assertTrue(r["vendor_ok"])
        self.assertIn("excess_bold", rules(r))

    def test_ascii_ioencoding_does_not_break_vendor(self):
        saved = os.environ.get("PYTHONIOENCODING")
        os.environ["PYTHONIOENCODING"] = "ascii"
        try:
            raw, ok = slop_scan.run_vendor("これは単なるツールではなく、チームの考え方そのものだ。\n")
        finally:
            if saved is None:
                del os.environ["PYTHONIOENCODING"]
            else:
                os.environ["PYTHONIOENCODING"] = saved
        self.assertTrue(ok)
        self.assertIn("negative_parallelism", [f["rule"] for f in raw])

    def test_invalid_utf8_exits_zero_without_traceback(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "b.bin")
            with open(p, "wb") as f:
                f.write(b"\xff\xfe")
            proc = subprocess.run([sys.executable, "-B", SCRIPT, p],
                                  capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0)
        self.assertNotIn("Traceback", proc.stderr)


class FixtureTest(unittest.TestCase):
    def test_non_slop_1_has_no_halfwidth_mixed(self):
        # 「Plan・Write・Edit」: ・ is punctuation, not a Japanese letter.
        with open(os.path.join(FIXTURES, "non-slop-1.md"), encoding="utf-8") as f:
            r = slop_scan.scan(f.read(), use_vendor=False)
        self.assertNotIn("halfwidth_mixed", rules(r))
        r = slop_scan.scan("Plan・Write・Edit を使う。", use_vendor=False)
        self.assertNotIn("halfwidth_mixed", rules(r))

    def test_non_slop_fixtures_have_no_pathology_findings(self):
        paths = sorted(glob.glob(os.path.join(FIXTURES, "non-slop-*.md")))
        self.assertTrue(paths, "no non-slop fixtures found under " + FIXTURES)
        for p in paths:
            with open(p, encoding="utf-8") as f:
                r = slop_scan.scan(f.read())
            hits = [(f["rule"], f["line"]) for f in r["findings"]
                    if f["pathology"] in ("1", "2", "3")]
            with self.subTest(fixture=os.path.basename(p)):
                self.assertEqual(hits, [])


class DocumentLevelRuleTest(unittest.TestCase):
    def test_excess_bold_survives_a_comment_on_line_one(self):
        path = os.path.join(FIXTURES, "slop-7.md")
        with open(path, encoding="utf-8") as f:
            r = slop_scan.scan(f.read())
        self.assertIn("excess_bold", rules(r, "3"))


class AsciiStdoutTest(unittest.TestCase):
    def test_ascii_stdout_keeps_exit_zero(self):
        env = dict(os.environ, PYTHONIOENCODING="ascii")
        proc = subprocess.run([sys.executable, "-B", SCRIPT, "-", "--json"],
                              input="保守性担保機能の形骸化の防止。".encode("utf-8"),
                              capture_output=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("nominal_chain", proc.stdout.decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
