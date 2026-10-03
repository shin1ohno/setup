"""Tests for content_diff.py. Repo-only: the cookbook does not deploy test_*.py.

Run: python3 -m unittest discover -s <this dir> -p 'test_*.py' -v
"""

import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import content_diff  # noqa: E402

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "content_diff.py")

# references/examples.md 例1 as it stood before the yomiyasu graft (captured
# 2026-10-03). The human version introduced two numbers the AI version never
# had, which is the failure this script exists to catch.
OLD_EXAMPLE1_AI = "本機能の導入により業務効率は大きく改善されました。今後の展開が注目されます。"
OLD_EXAMPLE1_HUMAN = "本機能で月次の手作業が 6 時間から 1 時間に減った。次は承認フローの自動化に着手する。"


def run_cli(before, after, *extra):
    with tempfile.TemporaryDirectory() as d:
        b, a = os.path.join(d, "b.md"), os.path.join(d, "a.md")
        with open(b, "w", encoding="utf-8") as f:
            f.write(before)
        with open(a, "w", encoding="utf-8") as f:
            f.write(after)
        return subprocess.run([sys.executable, "-B", SCRIPT, b, a] + list(extra),
                              capture_output=True, text=True)


class ContentDiffTest(unittest.TestCase):
    def test_changed_percentage_is_detected(self):
        r = content_diff.diff("エラー率は 2.1% だった。", "エラー率は 5.0% だった。")
        self.assertEqual(r["changed_numbers"], [{"before": "2.1%", "after": "5%"}])
        self.assertEqual(r["verdict"], "numbers_added")
        self.assertEqual(content_diff.exit_code(r), 1)

    def test_space_between_number_and_unit_is_ignored(self):
        r = content_diff.diff("処理に6時間かかる。", "処理に 6 時間かかる。")
        self.assertEqual(r["added_numbers"], [])
        self.assertEqual(r["changed_numbers"], [])
        self.assertEqual(r["dropped_numbers"], [])
        self.assertEqual(r["added_terms"], [])
        self.assertEqual(content_diff.exit_code(r), 0)

    def test_full_width_digits_are_normalised(self):
        r = content_diff.diff("対象は３件で、成功率は９５％。", "対象は 3 件で、成功率は 95%。")
        self.assertEqual(r["verdict"], "ok")
        self.assertEqual(r["added_numbers"], [])
        self.assertEqual(r["dropped_numbers"], [])

    def test_no_change_exits_zero(self):
        text = "API の p95 は 120 ms で、Redis のキャッシュヒット率は 87% だった。"
        proc = run_cli(text, text, "--json")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn('"verdict": "ok"', proc.stdout)

    def test_old_example1_rewrite_adds_6_and_1(self):
        r = content_diff.diff(OLD_EXAMPLE1_AI, OLD_EXAMPLE1_HUMAN)
        self.assertEqual(sorted(r["added_numbers"]), ["1時間", "6時間"])
        self.assertEqual(r["changed_numbers"], [])
        self.assertEqual(content_diff.exit_code(r), 1)
        proc = run_cli(OLD_EXAMPLE1_AI, OLD_EXAMPLE1_HUMAN)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("6時間", proc.stdout)
        self.assertIn("1時間", proc.stdout)

    def test_dropped_number_alone_is_advisory(self):
        r = content_diff.diff("3 件のうち 2 件が失敗した。", "3 件のうち一部が失敗した。")
        self.assertEqual(r["dropped_numbers"], ["2件"])
        self.assertEqual(r["verdict"], "ok")

    def test_range_and_identifiers(self):
        r = content_diff.diff("再試行は 3〜5 回。", "再試行は 3～5 回で、retry_max で設定する。")
        self.assertEqual(r["verdict"], "ok")
        self.assertIn("retry_max", r["added_terms"])

    def test_numbers_inside_identifiers_are_not_numbers(self):
        r = content_diff.diff("v1.2 を使う。", "v1.2 を使う。")
        self.assertEqual(r["added_numbers"], [])
        nums, _ = content_diff.extract_numbers("v1.2 を使う。")
        self.assertEqual(sum(nums.values()), 0)

    def test_html_comments_are_not_content(self):
        r = content_diff.diff("<!-- family: phrases.md 12 -->\n本文。", "本文。")
        self.assertEqual(r["dropped_numbers"], [])
        self.assertEqual(r["dropped_terms"], [])

    def test_terms_katakana_and_kanji(self):
        r = content_diff.diff("キャッシュを使う。", "キャッシュとデータベース移行を使う。")
        self.assertIn("データベース", r["added_terms"])
        self.assertIn("移行", r["added_terms"])
        self.assertEqual(r["verdict"], "ok")


def verdict(before, after):
    return content_diff.exit_code(content_diff.diff(before, after))


class ReviewRegressionTest(unittest.TestCase):
    """Repros from the scripts-adversarial review (2026-10-03)."""

    def assert_exit(self, cases, expected):
        for before, after in cases:
            with self.subTest(before=before, after=after):
                self.assertEqual(verdict(before, after), expected,
                                 content_diff.diff(before, after))

    def test_kanji_and_roman_numerals_are_numbers(self):
        self.assert_exit([("三つの理由", "四つの理由"), ("三倍速い", "四倍速い"),
                          ("第Ⅲ章", "第Ⅳ章"), ("二十件", "二十一件")], 1)
        r = content_diff.diff("三つの理由", "四つの理由")
        self.assertEqual(r["changed_numbers"], [{"before": "3つ", "after": "4つ"}])
        self.assertEqual(content_diff.kanji_to_int("三千五百"), 3500)
        self.assertEqual(content_diff.kanji_to_int("二〇二六"), 2026)
        self.assertEqual(content_diff.kanji_to_int("十二万"), 120000)

    def test_kanji_numerals_match_arabic_and_skip_words(self):
        self.assert_exit([("三日間かかる", "3日間かかる"), ("十分な時間", "十分な時間"),
                          ("十分に検討する", "よく検討する"), ("統一する", "統一する")], 0)

    def test_numbers_glued_to_latin_letters(self):
        self.assert_exit([("API 3件を処理", "API4件を処理"), ("v1.2 を使う", "v1.3 を使う"),
                          ("sha256", "sha512"), ("abc123", "abc124"), ("foo_2", "foo_3"),
                          ("0x1F", "0x2F"), ("x²", "x³"), ("0.5倍", ".7倍")], 1)

    def test_latin_digit_spacing_does_not_matter(self):
        self.assert_exit([("API3件を処理", "API 3件を処理"), ("Python3を使う", "Python 3を使う"),
                          ("ステップ.5", "ステップ 0.5")], 0)

    def test_new_identifier_alone_is_a_term(self):
        r = content_diff.diff("Redis を使う。", "Redis と S3 を使う。")
        self.assertIn("S3", r["added_terms"])
        self.assertEqual(r["verdict"], "ok")

    def test_sign_flip_is_a_change(self):
        self.assert_exit([("気温は-5度", "気温は5度"), ("−5%", "5%"), ("－5%", "5%")], 1)
        self.assert_exit([("+5%", "5%")], 0)

    def test_comma_is_thousands_only_in_1234_shape(self):
        self.assert_exit([("3,4件", "34件"), ("手順1,2,3件", "手順123件"), ("1,5倍", "15倍")], 1)
        self.assert_exit([("1,200件", "1200件")], 0)

    def test_range_and_date_rewrites_keep_values(self):
        self.assert_exit([("10〜20件", "10ー20件"), ("10-20件", "10〜20件"),
                          ("10〜20件", "10件〜20件"), ("2026年10月3日", "2026/10/3")], 0)

    def test_value_swap_between_subjects_is_a_documented_limitation(self):
        self.assertEqual(verdict("Aは3件、Bは5件", "Aは5件、Bは3件"), 0)
        self.assertIn("Swapping values between subjects", content_diff.__doc__)

    def test_invalid_utf8_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            bad, good = os.path.join(d, "bad.md"), os.path.join(d, "good.md")
            with open(bad, "wb") as f:
                f.write(b"\xff\xfe3\xe4")
            with open(good, "w", encoding="utf-8") as f:
                f.write("3件")
            proc = subprocess.run([sys.executable, "-B", SCRIPT, bad, good],
                                  capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)


class VerifyRegressionTest(unittest.TestCase):
    def test_ordinal_labels_are_not_numbers(self):
        r = content_diff.diff("重点は三つ。速度、費用、保守。",
                              "重点は三つある。一つ目に速度、二つ目に費用、3番目に保守。")
        self.assertEqual(r["added_numbers"], [])
        self.assertEqual(r["verdict"], "ok")

    def test_counter_change_next_to_ordinal_is_still_detected(self):
        r = content_diff.diff("重点は三つ。", "重点は四つ。一つ目は速度。")
        self.assertEqual(r["verdict"], "numbers_added")

    def test_internal_error_exits_2_not_1(self):
        original = content_diff.diff
        content_diff.diff = lambda b, a: (_ for _ in ()).throw(RuntimeError("boom"))
        try:
            with tempfile.TemporaryDirectory() as d:
                p = os.path.join(d, "x.md")
                with open(p, "w", encoding="utf-8") as f:
                    f.write("3 件")
                self.assertEqual(content_diff.main([p, p, "--json"]), 2)
        finally:
            content_diff.diff = original

    def test_ascii_stdout_does_not_crash(self):
        env = dict(os.environ, PYTHONIOENCODING="ascii")
        with tempfile.TemporaryDirectory() as d:
            b, a = os.path.join(d, "b.md"), os.path.join(d, "a.md")
            for p in (b, a):
                with open(p, "w", encoding="utf-8") as f:
                    f.write("処理は 3 件。")
            proc = subprocess.run([sys.executable, "-B", SCRIPT, b, a, "--json"],
                                  capture_output=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
