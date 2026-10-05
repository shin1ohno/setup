#!/usr/bin/env python3
"""content_diff.py - report numbers and terms a rewrite added, changed or dropped.

Usage: content_diff.py BEFORE AFTER [--json]

Both texts are NFKC-normalised (full-width digits and letters become ASCII,
U+2212 / U+FF0D minus signs become '-', Roman numerals Ⅰ-Ⅻ become digits) and
the ASCII spaces next to CJK characters are removed, so "6時間" and "6 時間"
compare equal. A space between a Latin word and a number followed by Japanese
text is also removed ("Python 3を" == "Python3を"), and a Latin word glued to a
number with a Japanese counter is split off ("API3件" == "API 3件").
Extracted tokens:

  numbers  integers/decimals with an optional sign and unit (%, 倍, 件, 時間,
           ms, MB, つ, 割, 章, ...); ranges such as 3〜5, 3-5, 3ー5, 3件〜5件;
           thousands separators only in the 1,234 shape (3,4 is two numbers);
           kanji numerals followed by a counter (三つ, 二十件, 第三章)
  ids      Latin identifiers containing digits (v1.2, sha256, 0x1F, p95). A
           value change inside the same identifier shape (v1.2 -> v1.3) is a
           changed number; an identifier that only appears on one side is a
           term difference
  terms    ASCII identifiers, katakana runs of 3+ chars, kanji runs of 2+ chars

Exit status: 1 when the rewrite added or changed at least one number, 0
otherwise (term differences are advisory), 2 on usage / IO / decoding errors.

Known limitations (the comparison is a multiset per unit, not positional):

  * Swapping values between subjects is invisible: "Aは3件、Bは5件" ->
    "Aは5件、Bは3件" reports ok. Check sentences that pair subjects with
    numbers by reading them.
  * changed_numbers pairs a dropped and an added number of the same unit in
    sorted order, so with several changes in one unit the before/after pairs
    can be the wrong way round ("1件、9件" -> "2件、8件" is shown as 1->2 and
    9->8 whatever the actual correspondence). The verdict is still correct.
  * A number whose unit is only removed or added on one side ("2026年" ->
    "2026") counts as unchanged.

Standard library only.
"""

import argparse
import json
import re
import sys
import unicodedata
from collections import Counter
from decimal import Decimal, InvalidOperation

CJK = r"぀-ゟ゠-ヿ㐀-䶿一-鿿々"
KANJI = r"㐀-䶿一-鿿々"

# Longest alternatives first so that 時間 wins over 時 and ヶ月 over 月.
UNITS = [
    "ヶ月", "か月", "時間", "ms", "KB", "MB", "GB",
    "%", "倍", "件", "個", "人", "回", "日", "分", "秒", "円", "万", "億",
    "年", "月", "週", "行", "本", "点", "つ", "割", "章",
]
_UNIT_RE = "|".join(re.escape(u) for u in UNITS)
_CJK_UNIT_RE = "|".join(re.escape(u) for u in UNITS if not re.match(r"[A-Za-z%]", u))
# 1,234 shape first; any other comma separates two numbers ("3,4" is 3 and 4).
_NUM = r"(?:\d{1,3}(?:,\d{3})+(?![\d,])(?:\.\d+)?|\d+(?:\.\d+)*|\.\d+)"
_RANGE_SEP = r"[〜~–ー\-]"
NUMBER_RE = re.compile(
    r"(?<![0-9A-Za-z_.])"
    r"(?P<sign>[-+](?=[\d.]))?"
    r"(?P<v1>" + _NUM + r")"
    r"(?:(?:[ \t]?(?P<u1>" + _UNIT_RE + r"))?[ \t]*" + _RANGE_SEP + r"[ \t]*(?P<v2>" + _NUM + r"))?"
    r"(?:[ \t]?(?P<unit>" + _UNIT_RE + r")(?![A-Za-z]))?"
)
# Latin identifiers that contain a digit; filtered for the digit in code.
MIXED_RE = re.compile(
    r"(?<![A-Za-z0-9_.])(?:0[xX][0-9A-Fa-f]+|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*)"
)
KANJI_DIGITS = {"〇": 0, "一": 1, "二": 2, "三": 3, "四": 4,
                "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
KANJI_SMALL = {"十": 10, "百": 100, "千": 1000}
KANJI_LARGE = {"万": 10 ** 4, "億": 10 ** 8}
KANJI_COUNTERS = [
    "時間", "ヶ月", "か月", "つ", "倍", "割", "件", "個", "人", "回", "日", "分",
    "秒", "円", "年", "月", "週", "行", "本", "点", "章",
]
KANJI_NUMBER_RE = re.compile(
    r"(?:(?<=第)|(?<![" + KANJI + r"]))"
    r"(?P<k>[〇一二三四五六七八九十百千][〇一二三四五六七八九十百千万億]*)"
    r"(?P<unit>" + "|".join(re.escape(u) for u in KANJI_COUNTERS) + r")"
)
ROMAN = {chr(0x2160 + i): str(i + 1) for i in range(12)}
ROMAN.update({chr(0x2170 + i): str(i + 1) for i in range(12)})

IDENT_RE = re.compile(r"(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_./-]+")
KATAKANA_RE = re.compile(r"[ァ-ヺー]{3,}")
KANJI_RE = re.compile(r"[" + KANJI + r"]{2,}")
SPACE_NEAR_CJK_RE = re.compile(
    r"(?<=[" + CJK + r"])[ \t]+(?=\S)|(?<=\S)[ \t]+(?=[" + CJK + r"])"
)
# "Python 3を" -> "Python3を": a Latin word and a number followed by Japanese.
SPACE_LATIN_DIGIT_RE = re.compile(r"(?<=[A-Za-z])[ \t]+(?=\d[\d.,]*[" + CJK + r"])")
# "API3件" -> "API 3件": the number belongs to the counter, not the word.
SPLIT_LATIN_COUNTER_RE = re.compile(
    r"(?<![A-Za-z0-9_.])([A-Za-z]+)(?=\d+(?:[.,]\d+)*(?:" + _CJK_UNIT_RE + r"))"
)


HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
# Enumeration labels (一つ目, 2番目, 3点目) order items; they are not facts, so
# a rewrite that numbers the points it lists must not read as adding numbers.
ORDINAL_LABEL_RE = re.compile(r"(?<![〇一二三四五六七八九十百千\d])[〇一二三四五六七八九十\d]+(?:つ|番|点)目")


def normalize(text):
    """NFKC plus the spacing rules described in the module docstring.

    HTML comments (fixture headers, editor notes) are not content and are
    dropped first.
    """
    text = HTML_COMMENT_RE.sub(" ", text)
    text = "".join(ROMAN.get(c, c) for c in text)
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("−", "-")
    text = ORDINAL_LABEL_RE.sub(" ", text)
    text = SPACE_NEAR_CJK_RE.sub("", text)
    text = SPACE_LATIN_DIGIT_RE.sub("", text)
    return SPLIT_LATIN_COUNTER_RE.sub(r"\1 ", text)


def _canon_value(raw, sign=""):
    """Canonical form of one number: thousands commas dropped, 5.0 == 5, +5 == 5."""
    raw = raw.replace(",", "")
    try:
        d = Decimal(sign + raw).normalize()
    except InvalidOperation:
        return ("-" if sign == "-" else "") + raw
    s = format(d, "f")
    return "0" if s == "-0" else s


def kanji_to_int(s):
    if not any(c in KANJI_SMALL or c in KANJI_LARGE for c in s):
        return int("".join(str(KANJI_DIGITS[c]) for c in s))
    total = section = current = 0
    for c in s:
        if c in KANJI_DIGITS:
            current = current * 10 + KANJI_DIGITS[c]
        elif c in KANJI_SMALL:
            section += (current or 1) * KANJI_SMALL[c]
            current = 0
        else:
            total += ((section + current) or 1) * KANJI_LARGE[c]
            section = current = 0
    return total + section + current


def _number_key(m):
    v = _canon_value(m.group("v1"), m.group("sign") or "")
    unit = m.group("unit") or ""
    if m.group("v2") is not None:
        u1 = m.group("u1") or ""
        if u1 and unit and u1 != unit:
            unit = u1 + "〜" + unit
        else:
            unit = unit or u1
        v = v + "〜" + _canon_value(m.group("v2"))
    return (v, unit)


def _kanji_matches(norm):
    for m in KANJI_NUMBER_RE.finditer(norm):
        nxt = norm[m.end():m.end() + 1]
        # 十分な / 十分に / 十分だ / 十分で mean "enough", not ten minutes.
        if m.group("k") == "十" and m.group("unit") == "分" and nxt and nxt in "なにだで":
            continue
        yield m


def _mixed_matches(norm):
    for m in MIXED_RE.finditer(norm):
        if re.search(r"\d", m.group(0)):
            yield m


def _blank(text, spans):
    out, pos = [], 0
    for start, end in sorted(spans):
        if start < pos:
            continue
        out.append(text[pos:start])
        out.append(" ")
        pos = end
    out.append(text[pos:])
    return "".join(out)


def extract_all(text):
    """Return (numbers Counter, mixed-identifier Counter, blanked text).

    numbers keys are (value, unit); mixed keys are the identifier itself.
    """
    norm = normalize(text)
    mixed = Counter()
    spans = []
    for m in _mixed_matches(norm):
        mixed[m.group(0)] += 1
        spans.append(m.span())
    norm = _blank(norm, spans)
    found = Counter()
    spans = []
    for m in _kanji_matches(norm):
        found[(str(kanji_to_int(m.group("k"))), m.group("unit"))] += 1
        spans.append(m.span())
    norm = _blank(norm, spans)
    spans = []
    for m in NUMBER_RE.finditer(norm):
        found[_number_key(m)] += 1
        spans.append(m.span())
    return found, mixed, _blank(norm, spans)


def extract_numbers(text):
    """Return (Counter of (value, unit) keys, normalised text with numbers blanked)."""
    found, _, blanked = extract_all(text)
    return found, blanked


def extract_terms(blanked):
    terms = set()
    for rx in (IDENT_RE, KATAKANA_RE, KANJI_RE):
        terms.update(m.group(0) for m in rx.finditer(blanked))
    # Trailing punctuation picked up by the identifier pattern ("foo." at a
    # sentence end) is not part of the identifier.
    return {t.rstrip("./-") for t in terms if t.rstrip("./-")}


def _show(key):
    value, unit = key
    return value + unit


def _skeleton(ident):
    return re.sub(r"\d+", "#", ident)


def diff(before, after):
    nb, mb, blank_b = extract_all(before)
    na, ma, blank_a = extract_all(after)
    added = na - nb
    dropped = nb - na

    # A dropped and an added number with the same unit are reported as one
    # change (2.1% -> 5.0%). Pairing is by unit only, in sorted order.
    changed = []
    by_unit_added = {}
    for key, n in sorted(added.items()):
        by_unit_added.setdefault(key[1], []).extend([key] * n)
    by_unit_dropped = {}
    for key, n in sorted(dropped.items()):
        by_unit_dropped.setdefault(key[1], []).extend([key] * n)
    for unit in sorted(set(by_unit_added) & set(by_unit_dropped)):
        a_list, d_list = by_unit_added[unit], by_unit_dropped[unit]
        while a_list and d_list:
            a_key, d_key = a_list.pop(0), d_list.pop(0)
            changed.append({"before": _show(d_key), "after": _show(a_key)})
            added[a_key] -= 1
            dropped[d_key] -= 1

    # The same value with its unit removed or added on one side only
    # (2026年 -> 2026) is not a new number.
    for a_key in sorted(k for k, n in added.items() if n > 0):
        for d_key in sorted(k for k, n in dropped.items() if n > 0):
            if a_key[0] != d_key[0] or (a_key[1] and d_key[1]):
                continue
            k = min(added[a_key], dropped[d_key])
            added[a_key] -= k
            dropped[d_key] -= k
            if added[a_key] <= 0:
                break

    # Identifiers with digits: a value change within the same shape
    # (v1.2 -> v1.3, sha256 -> sha512) is a changed number; the rest are terms.
    m_added, m_dropped = ma - mb, mb - ma
    by_shape_dropped = {}
    for ident, n in sorted(m_dropped.items()):
        by_shape_dropped.setdefault(_skeleton(ident), []).extend([ident] * n)
    extra_added_terms, extra_dropped_terms = set(), set()
    for ident, n in sorted(m_added.items()):
        for _ in range(n):
            pool = by_shape_dropped.get(_skeleton(ident))
            if pool:
                changed.append({"before": pool.pop(0), "after": ident})
            else:
                extra_added_terms.add(ident)
    for pool in by_shape_dropped.values():
        extra_dropped_terms.update(pool)

    def expand(counter):
        out = []
        for key, n in sorted(counter.items()):
            out.extend([_show(key)] * max(n, 0))
        return out

    tb, ta = extract_terms(blank_b), extract_terms(blank_a)
    added_numbers = expand(added)
    result = {
        "added_numbers": added_numbers,
        "dropped_numbers": expand(dropped),
        "changed_numbers": changed,
        "added_terms": sorted((ta - tb) | extra_added_terms),
        "dropped_terms": sorted((tb - ta) | extra_dropped_terms),
    }
    result["verdict"] = "numbers_added" if (added_numbers or changed) else "ok"
    return result


def exit_code(result):
    return 1 if result["verdict"] == "numbers_added" else 0


def render_text(result):
    lines = []
    lines.append("数値: 追加 %d / 変更 %d / 削除 %d" % (
        len(result["added_numbers"]), len(result["changed_numbers"]),
        len(result["dropped_numbers"])))
    if result["added_numbers"]:
        lines.append("  追加された数値: " + "、".join(result["added_numbers"]))
    for c in result["changed_numbers"]:
        lines.append("  変更された数値: %s → %s" % (c["before"], c["after"]))
    if result["dropped_numbers"]:
        lines.append("  削除された数値: " + "、".join(result["dropped_numbers"]))
    lines.append("語: 追加 %d / 削除 %d（助言）" % (
        len(result["added_terms"]), len(result["dropped_terms"])))
    if result["added_terms"]:
        lines.append("  追加された語: " + "、".join(result["added_terms"]))
    if result["dropped_terms"]:
        lines.append("  削除された語: " + "、".join(result["dropped_terms"]))
    if result["verdict"] == "numbers_added":
        lines.append("判定: numbers_added — 原文にない数値か、値の変わった数値がある（exit 1）")
    else:
        lines.append("判定: ok（exit 0）")
    return "\n".join(lines)


def _read(path):
    if path == "-":
        # UTF-8 regardless of the locale, same as slop_scan.py.
        return sys.stdin.buffer.read().decode("utf-8")
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Report numbers/terms a rewrite added, changed or dropped.")
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.before == "-" and args.after == "-":
        parser.error("only one of BEFORE / AFTER may be '-'")
    try:
        before, after = _read(args.before), _read(args.after)
    except (OSError, UnicodeDecodeError) as e:
        print("content_diff: %s" % e, file=sys.stderr)
        return 2
    try:
        result = diff(before, after)
    except Exception as e:  # noqa: BLE001 — an uncaught crash exits 1, which reads as numbers_added
        print("content_diff: internal error: %r" % (e,), file=sys.stderr)
        return 2
    # Japanese output on an ASCII-only stdout must not crash into exit 1,
    # which callers would read as the numbers_added verdict.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(render_text(result))
    return exit_code(result)


if __name__ == "__main__":
    sys.exit(main())
