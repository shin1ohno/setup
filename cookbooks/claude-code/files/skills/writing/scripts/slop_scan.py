#!/usr/bin/env python3
"""slop_scan.py - advisory scan for the three pathologies in structures.md 1-3.

Usage: slop_scan.py FILE [--json]      (FILE may be '-' for stdin)

Combines two sources into one report:

  * the bundled vendor/yomiyasu_lint.py (run with --json), filtered down to the
    rules this skill adopts:
      pathology 1  metaphor_verb, slop_vocabulary
      pathology 3  negative_parallelism, excess_bold, excess_list, emoji_prohibited
      other        meta_filler (phrases.md 3 / 5)
    Rules this skill decided against (unnatural_halfwidth_space, trailing_colon,
    redundant_bracket, sentence_end_repetition, bold_not_rendered) are dropped
    silently; any rule id not known here is dropped and listed in
    "dropped_rules" so an upstream rename is visible. Vendor findings on
    lines that are not content (front matter, code, HTML comments, as
    classify_lines() sees them) are dropped too.
  * this script's own detectors:
      pathology 1  inanimate_agency - an abstract/inanimate noun + が/は whose
                                    predicate is an embodied verb from a short
                                    list (データが物語る, 施策が成長を加速させる);
                                    person and organisation subjects are skipped.
                                    Pathology 1 coverage is limited to this list
                                    and the vendor phrase lists: 0 findings does
                                    not mean the text is free of pathology 1
      pathology 2  nominal_chain  - 3+ kanji/katakana nouns (2+ chars each)
                                    joined by の (保守性担保機能の形骸化の防止)
                   taigen_run     - 3+ consecutive prose sentences ending in a
                                    noun, outside tables, lists, headings, code
      other        halfwidth_mixed - the document mixes "日本語 ASCII" and
                                    "日本語ASCII" (only mixing is reported)

Exit status is always 0: findings are advice for the editor, not a gate.
Standard library only.

Attribution: the vendored lint and the nominal_chain example
(保守性担保機能の形骸化の防止) come from nanaism/yomiyasu (MIT, © 2026 nanaism,
@8d5abeeb); the detectors in this file are re-authored.
"""

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR_LINT = os.path.join(HERE, "vendor", "yomiyasu_lint.py")

KEEP_RULES = {
    "metaphor_verb": "1",
    "slop_vocabulary": "1",
    "negative_parallelism": "3",
    "excess_bold": "3",
    "excess_list": "3",
    "emoji_prohibited": "3",
    "meta_filler": None,
}
DOCUMENT_LEVEL_RULES = {"excess_bold", "excess_list"}
KNOWN_DROPPED_RULES = {
    "unnatural_halfwidth_space",
    "trailing_colon",
    "redundant_bracket",
    "sentence_end_repetition",
    "bold_not_rendered",
}

KANJI = r"㐀-䶿一-鿿々"
KATA = r"ァ-ヺー"
# Letters only: ・ (U+30FB), ー (U+30FC) and ゠ are punctuation-like and do not
# make "Plan・Write" a Japanese/ASCII adjacency.
JA = r"぀-ゟァ-ヺヽ-ヿ" + KANJI
NOUN = r"[" + KANJI + KATA + r"]{2,}"
NOMINAL_CHAIN_MIN = 3
NOMINAL_CHAIN_RE = re.compile(
    r"(?<![" + KANJI + KATA + r"])" + NOUN + r"(?:の" + NOUN + r"){%d,}" % (NOMINAL_CHAIN_MIN - 1)
)
TAIGEN_RUN_MIN = 3
# Sentence-final nouns written in hiragana that still make a 体言止め.
HIRAGANA_NOUN_ENDINGS = ("こと", "もの", "ところ", "ため")
SENTENCE_END_RE = re.compile(r"[。！？!?]")
CLOSERS = "」』）)】〕\"'”’*_ 　"

LIST_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")


def run_vendor(text):
    """Return (findings, ok). ok is False when the vendor lint cannot run or
    returns JSON of an unexpected shape."""
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
    try:
        proc = subprocess.run(
            [sys.executable, VENDOR_LINT, "--json"],
            input=text, capture_output=True, text=True, encoding="utf-8",
            timeout=60, env=env,
        )
        data = json.loads(proc.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return [], False
    if not isinstance(data, dict) or not isinstance(data.get("findings", []), list):
        return [], False
    return [f for f in data.get("findings", []) if isinstance(f, dict)], True


def filter_vendor(findings):
    kept, unknown = [], set()
    for f in findings:
        if not isinstance(f, dict):
            continue
        rule = f.get("rule")
        if not isinstance(rule, str):
            unknown.add(str(rule))
            continue
        if rule in KEEP_RULES:
            kept.append({
                "rule": rule,
                "pathology": KEEP_RULES[rule],
                "line": f.get("line") if isinstance(f.get("line"), int) else None,
                "snippet": str(f.get("snippet", "")),
                "message": str(f.get("message", "")),
            })
        elif rule not in KNOWN_DROPPED_RULES:
            unknown.add(str(rule))
    return kept, sorted(unknown)


def _strip_inline(line):
    line = re.sub(r"`[^`]*`", " ", line)
    line = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", line)
    line = re.sub(r"https?://\S+", " ", line)
    line = re.sub(r"<[^>]+>", "", line)
    line = re.sub(r"\*\*|__|\*", "", line)
    return line


FENCE_OPEN_RE = re.compile(r"^\s*(`{3,}|~{3,})")
FENCE_CLOSE_RE = re.compile(r"^\s*(`{3,}|~{3,})\s*$")
FRONT_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+\s*:(?:\s|$)")
INDENTED_RE = re.compile(r"^(?: {4}|\t)")


def _front_matter_end(lines):
    """Index of the first line after front matter (0 when there is none).

    Without a closing '---' the leading run of 'key: value' lines after the
    opening '---' is still treated as front matter.
    """
    if not lines or lines[0].strip() != "---":
        return 0
    for i in range(1, len(lines)):
        if lines[i].strip() in ("---", "..."):
            return i + 1
    i = 1
    while i < len(lines) and FRONT_KEY_RE.match(lines[i]):
        i += 1
    return i


def classify_lines(text):
    """Yield (line_no, kind, content); kind is prose/blank/other.

    kind "other" with empty content marks a line that is not content at all
    (front matter, code, an HTML comment); "other" with content is a heading,
    list item, table row, quote or HTML line.
    """
    lines = text.split("\n")
    start = _front_matter_end(lines)
    fence = None          # (char, length) of the open code fence
    in_comment = False
    prev_blank = True
    in_indented = False
    after_list = False    # indented lines after a list item are continuations
    for idx, raw in enumerate(lines):
        no = idx + 1
        if idx < start:
            yield no, "other", ""
            continue
        if fence:
            m = FENCE_CLOSE_RE.match(raw)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= fence[1]:
                fence = None
            yield no, "other", ""
            continue
        line = raw
        had_comment = in_comment
        if in_comment:
            if "-->" not in line:
                yield no, "other", ""
                continue
            in_comment = False
            line = line.split("-->", 1)[1]
        if "<!--" in line:
            had_comment = True
            line = re.sub(r"<!--.*?-->", " ", line)
            if "<!--" in line:
                line, in_comment = line.split("<!--", 1)[0], True
        s = line.strip()
        if had_comment and not s:
            yield no, "other", ""
            continue
        m = FENCE_OPEN_RE.match(line)
        if m:
            fence = (m.group(1)[0], len(m.group(1)))
            prev_blank = in_indented = False
            yield no, "other", ""
            continue
        if not s:
            prev_blank = True
            yield no, "blank", ""
            continue
        indented = bool(INDENTED_RE.match(line))
        if indented and not after_list and (prev_blank or in_indented):
            in_indented, prev_blank = True, False
            yield no, "other", ""
            continue
        in_indented = prev_blank = False
        is_list = bool(LIST_RE.match(line))
        if is_list:
            after_list = True
        elif not indented:
            after_list = False
        if (s.startswith("#") or s.startswith("|") or s.startswith(">")
                or is_list or s.startswith("<") or s.startswith("![")
                or re.fullmatch(r"[-*_=]{3,}", s)):
            yield no, "other", s
            continue
        yield no, "prose", _strip_inline(s)


# Embodied verbs with an inanimate subject (structures.md 1). Each pattern
# covers the conjugated stems that keep the verb reading.
# A kanji right before the verb means it is part of another word (日本語って,
# 催促した, 深呼吸する), so every pattern requires a non-kanji before it.
EMBODIED_VERBS = [
    r"物語(?:る|っ|り|ら|れ)",
    r"語(?:る|って|った|り[かだ]|られ)",
    r"加速させ",
    r"牽引(?:する|し[たてま])",
    r"後押し(?:する|し[たてま])",
    r"もたら(?:す|し|さ)",
    r"生(?:む|んで|んだ|み出)",
    r"浮き彫りに",
    r"促(?:す|し[たてま]|さ)",
    r"呼吸(?:する|し[たてま])",
    r"支え(?:る|た|て|ま|ら)",
]
INANIMATE_AGENCY_RE = re.compile(
    r"(?<![" + KANJI + KATA + r"])(?P<subj>[" + KANJI + KATA + r"]{2,})(?:が|は)"
    r"(?P<mid>[^。！？!?\nがは]{0,25}?)(?<![" + KANJI + r"])(?P<verb>"
    + "|".join(EMBODIED_VERBS) + r")"
)
# Subjects that are people or groups of people; their agency is literal.
PERSON_SUFFIXES = (
    "者", "員", "人", "長", "家", "手", "師", "士", "氏", "主", "陣", "民",
    "様", "方", "生", "達", "社", "省", "庁", "局", "課", "会", "団", "隊",
    "部", "府", "国", "党",
)
PERSON_WORDS = {
    "チーム", "メンバー", "ユーザー", "ユーザ", "顧客", "彼女", "彼ら", "自分",
    "我々", "私達", "組織", "企業", "現場", "上司", "部下", "先輩", "後輩",
    "子供", "家族", "仲間", "自治体", "行政", "経営", "スタッフ", "クライアント",
    "パートナー", "エンジニア", "デザイナー", "マネージャー", "リーダー",
}


def _is_person(subj):
    return subj in PERSON_WORDS or subj.endswith(PERSON_SUFFIXES)


def detect_inanimate_agency(text):
    out = []
    for no, kind, content in classify_lines(text):
        if kind != "prose":
            continue
        for m in INANIMATE_AGENCY_RE.finditer(content):
            if _is_person(m.group("subj")):
                continue
            out.append({
                "rule": "inanimate_agency",
                "pathology": "1",
                "line": no,
                "snippet": m.group(0),
                "message": "非生物の主語「%s」に身体性のある動詞「%s」が付いている。実際に動いた人・仕組みを主語にした文に開けるか確かめる（補う主語は前後の文にあるものだけ）。" % (
                    m.group("subj"), m.group("verb")),
            })
    return out


def detect_nominal_chain(text):
    out = []
    for no, kind, content in classify_lines(text):
        if kind != "prose":
            continue
        for m in NOMINAL_CHAIN_RE.finditer(content):
            n = m.group(0).count("の") + 1
            out.append({
                "rule": "nominal_chain",
                "pathology": "2",
                "line": no,
                "snippet": m.group(0),
                "message": "漢語名詞が「の」で %d つつながっている。動作主・対象・動作が見える動詞文に開けるか確かめる（補う語は前後の文にあるものだけ）。" % n,
            })
    return out


def _is_taigen(sentence):
    s = sentence.rstrip("。．.！？!?" + CLOSERS)
    if not s or not re.search(r"[" + JA + r"]", s):
        # Not Japanese prose (scraped metadata, an English line): out of scope.
        return False
    if s.endswith(HIRAGANA_NOUN_ENDINGS):
        return True
    ch = s[-1]
    return bool(re.match(r"[" + KANJI + KATA + r"A-Za-z0-9０-９Ａ-Ｚａ-ｚ]", ch))


def split_sentences(text):
    """Return a list of sentence groups; each group is [(line_no, sentence)].

    A group is a run of prose uninterrupted by headings, lists, tables or
    code. Blank lines separate paragraphs but do not end a group.
    """
    groups, current = [], []
    buf, buf_line = "", None
    for no, kind, content in classify_lines(text):
        if kind == "blank":
            if buf.strip():
                current.append((buf_line, buf.strip()))
            buf, buf_line = "", None
            continue
        if kind == "other":
            if buf.strip():
                current.append((buf_line, buf.strip()))
            buf, buf_line = "", None
            if current:
                groups.append(current)
            current = []
            continue
        pos = 0
        for m in SENTENCE_END_RE.finditer(content):
            piece = content[pos:m.end()]
            if buf_line is None:
                buf_line = no
            buf += piece
            if buf.strip():
                current.append((buf_line, buf.strip()))
            buf, buf_line = "", None
            pos = m.end()
        rest = content[pos:]
        if rest.strip():
            if buf_line is None:
                buf_line = no
            buf += rest
    if buf.strip():
        current.append((buf_line, buf.strip()))
    if current:
        groups.append(current)
    return groups


def detect_taigen_run(text):
    out = []
    for group in split_sentences(text):
        run = []
        for item in group + [(None, "")]:
            if item[0] is not None and _is_taigen(item[1]):
                run.append(item)
                continue
            if len(run) >= TAIGEN_RUN_MIN:
                snippet = " ".join(s for _, s in run[:3])
                if len(snippet) > 120:
                    snippet = snippet[:120] + "…"
                out.append({
                    "rule": "taigen_run",
                    "pathology": "2",
                    "line": run[0][0],
                    "snippet": snippet,
                    "message": "体言止めの文が %d 文続いている。述語のある文に開けるか確かめる（補う語は前後の文にあるものだけ）。" % len(run),
                })
            run = []
    return out


def detect_halfwidth_mixed(text):
    spaced, tight = [], []
    sp = re.compile(r"[" + JA + r"][ ]+[A-Za-z0-9]|[A-Za-z0-9][ ]+[" + JA + r"]")
    tg = re.compile(r"[" + JA + r"][A-Za-z0-9]|[A-Za-z0-9][" + JA + r"]")
    for no, kind, content in classify_lines(text):
        if kind == "blank":
            continue
        if kind == "other":
            s = content
            if not s or s.startswith("|") or s.startswith("<"):
                continue
            content = _strip_inline(LIST_RE.sub("", s).lstrip("#> "))
        n_sp = len(sp.findall(content))
        n_tg = len(tg.findall(content))
        spaced.extend([no] * n_sp)
        tight.extend([no] * n_tg)
    if not spaced or not tight:
        return []
    minority, label = (spaced, "空白あり") if len(spaced) <= len(tight) else (tight, "空白なし")
    return [{
        "rule": "halfwidth_mixed",
        "pathology": None,
        "line": minority[0],
        "snippet": "空白あり %d 箇所 / 空白なし %d 箇所" % (len(spaced), len(tight)),
        "message": "和欧文の間の空白が文書内で混在している（少ない方は%s）。多い方にそろえる。空白の有無そのものは問わない。" % label,
    }]


def scan(text, use_vendor=True):
    vendor_ok = False
    kept, unknown = [], []
    if use_vendor:
        raw, vendor_ok = run_vendor(text)
        kept, unknown = filter_vendor(raw)
        non_content = {no for no, kind, content in classify_lines(text)
                       if kind == "other" and not content}
        # excess_bold / excess_list are document-wide densities that the vendor
        # pins to line 1; that line being a comment says nothing about them.
        kept = [f for f in kept
                if f["rule"] in DOCUMENT_LEVEL_RULES or f["line"] not in non_content]
    findings = (kept + detect_inanimate_agency(text) + detect_nominal_chain(text)
                + detect_taigen_run(text) + detect_halfwidth_mixed(text))
    findings.sort(key=lambda f: (f["line"] or 0, f["rule"]))
    by = {"1": 0, "2": 0, "3": 0, "other": 0}
    for f in findings:
        by[f["pathology"] if f["pathology"] in ("1", "2", "3") else "other"] += 1
    return {
        "findings": findings,
        "by_pathology": by,
        "dropped_rules": unknown,
        "vendor_ok": vendor_ok,
    }


LABELS = [
    ("1", "病理① 非生物主語 ＋ 身体性比喩動詞（structures.md 1 / phrases.md 2・9）"),
    ("2", "病理② SVOCM 統語の消失と過剰な名詞化（structures.md 2）"),
    ("3", "病理③ 形式インフレと架空の敵を立てる否定対比（structures.md 3）"),
    (None, "その他（phrases.md 3・5・8）"),
]


def render_text(result):
    out = []
    by = result["by_pathology"]
    out.append("slop_scan: 病理① %d / 病理② %d / 病理③ %d / その他 %d（助言、exit 0）" % (
        by["1"], by["2"], by["3"], by["other"]))
    out.append("注: 病理①は動詞・語彙のリストに載った形だけを検出する。0 件でも病理①がないとは限らない。")
    if not result["vendor_ok"]:
        out.append("注意: vendor/yomiyasu_lint.py を実行できなかったため、vendor 由来の規則"
                   "（metaphor_verb・slop_vocabulary・病理③全部・meta_filler）は実行されていない。"
                   "病理①の inanimate_agency と病理②は実行済み。")
    for key, label in LABELS:
        items = [f for f in result["findings"] if f["pathology"] == key]
        if not items:
            continue
        out.append("")
        out.append("## " + label)
        for f in items:
            out.append("L%s [%s] %s" % (f["line"], f["rule"], f["message"]))
            out.append("  > %s" % f["snippet"])
    if result["dropped_rules"]:
        out.append("")
        out.append("未知の vendor ルールを除外: " + ", ".join(result["dropped_rules"]))
    return "\n".join(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Advisory scan for pathologies 1-3.")
    parser.add_argument("file", help="Markdown file, or '-' for stdin")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.file == "-":
            # Decode as UTF-8 regardless of the locale's stdin encoding.
            text = sys.stdin.buffer.read().decode("utf-8")
        else:
            with open(args.file, "r", encoding="utf-8") as f:
                text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        print("slop_scan: %s" % e, file=sys.stderr)
        return 0
    result = scan(text)
    # The output is Japanese; an ASCII-only stdout (PYTHONIOENCODING=ascii,
    # LANG=C on some hosts) must not turn the always-0 contract into a crash.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(render_text(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
