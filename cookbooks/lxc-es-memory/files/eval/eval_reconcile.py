#!/usr/bin/env python3
"""Reconcile-verdict eval for the memory-keeper judge.

Drives every case in ``reconcile_cases.jsonl`` through the keeper's reconcile
judge (``claude -p`` inference, contract §6), applies the ID-integrity guard,
compares the returned verdict against the labelled ``expect_verdict``, and
prints a confusion matrix.

Judge resolution order:
  1. If ``memory-keeper/files/keeper/claude_judge.py`` is importable and exposes
     a ``judge(new_fact, candidates, model=...)`` callable, use it (single
     source of truth with the running keeper).
  2. Otherwise fall back to an inline judge that mirrors the frozen contract §6
     invocation + parse + guard, so the eval runs standalone.

Env (contract §2c keeper.env names):
    CLAUDE_BIN        (default: "claude")
    RECONCILE_MODEL   (default: "sonnet")
Eval knobs:
    RECONCILE_CASES   (default: reconcile_cases.jsonl next to this file)
    JUDGE_TIMEOUT     (default: 120 seconds)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.environ.get("RECONCILE_CASES", os.path.join(HERE, "reconcile_cases.jsonl"))
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
RECONCILE_MODEL = os.environ.get("RECONCILE_MODEL", "sonnet")
JUDGE_TIMEOUT = int(os.environ.get("JUDGE_TIMEOUT", "120"))

VERDICTS = ("ADD", "UPDATE", "NOOP")

# keeper module lives at cookbooks/memory-keeper/files/keeper (contract §9).
_KEEPER_DIR = os.path.abspath(
    os.path.join(HERE, "..", "..", "..", "memory-keeper", "files", "keeper"))
if os.path.isdir(_KEEPER_DIR):
    sys.path.insert(0, _KEEPER_DIR)


def load_jsonl(path: str) -> list[dict]:
    rows: list[dict] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{lineno} invalid JSON: {exc}") from exc
    return rows


# --------------------------------------------------------------------------- #
# Inline judge (mirrors contract §6; used when keeper module is unavailable)
# --------------------------------------------------------------------------- #
def _read_prompt_template() -> str:
    """Prefer the keeper's committed reconcile prompt; fall back to inline."""
    candidate = os.path.join(_KEEPER_DIR, "prompts", "reconcile.md")
    if os.path.isfile(candidate):
        try:
            with open(candidate, encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            pass
    return (
        "You are a memory reconciliation judge. Given a NEW fact and up to 10 "
        "candidate existing facts (retrieved by semantic similarity), decide:\n"
        "- ADD: genuinely new information; no candidate expresses the same fact.\n"
        "- UPDATE: the new fact supersedes/corrects a SPECIFIC candidate (same "
        "subject, changed value). Set target_id to that candidate's id and "
        "merged_content to the single reconciled fact.\n"
        "- NOOP: a paraphrase/duplicate of an existing candidate (no new info).\n"
        "Respond with ONLY a JSON object and nothing else:\n"
        '{"verdict":"ADD|UPDATE|NOOP","target_id":<candidate id or null>,'
        '"merged_content":<string or null>,"reason":<string>}'
    )


def _build_prompt(new_fact: str, candidates: list[dict]) -> str:
    lines = [f"- id={c.get('id')} | {c.get('content', '')}" for c in candidates]
    cand_block = "\n".join(lines) if lines else "(none)"
    return (
        f"{_read_prompt_template()}\n\n"
        f"NEW fact:\n{new_fact}\n\n"
        f"Candidates:\n{cand_block}\n"
    )


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        # drop the opening fence line (``` or ```json) and the closing fence
        parts = text.split("\n")
        if parts and parts[0].startswith("```"):
            parts = parts[1:]
        if parts and parts[-1].strip().startswith("```"):
            parts = parts[:-1]
        text = "\n".join(parts).strip()
    return text


def _invoke_claude(prompt: str, model: str) -> dict:
    """Run `claude -p` (pure inference, no tools) and parse the verdict JSON."""
    cmd = [CLAUDE_BIN, "-p", prompt, "--output-format", "json",
           "--model", model, "--strict-mcp-config", "--mcp-config", "{}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=JUDGE_TIMEOUT)
    if proc.returncode != 0:
        raise RuntimeError(f"claude exited {proc.returncode}: {proc.stderr[:200]}")
    outer = json.loads(proc.stdout)
    inner = _strip_fences(outer["result"])
    return json.loads(inner)


def _apply_guard(verdict: dict, candidate_ids: list[str]) -> str:
    """ID-integrity guard (contract §6): UPDATE with an out-of-set target_id
    downgrades to ADD."""
    v = str(verdict.get("verdict", "")).upper()
    if v == "UPDATE" and verdict.get("target_id") not in candidate_ids:
        return "ADD"
    return v if v in VERDICTS else "ERROR"


def _inline_judge(new_fact: str, candidates: list[dict], model: str = RECONCILE_MODEL) -> str:
    candidate_ids = [c.get("id") for c in candidates]
    prompt = _build_prompt(new_fact, candidates)
    last_err: Exception | None = None
    for _ in range(2):  # 1 retry on parse/inference failure (contract §6)
        try:
            verdict = _invoke_claude(prompt, model)
            return _apply_guard(verdict, candidate_ids)
        except Exception as exc:  # noqa: BLE001 — retry then surface as ERROR
            last_err = exc
    print(f"  judge error: {last_err}", file=sys.stderr)
    return "ERROR"


def _resolve_judge():
    """Return a callable judge(new_fact, candidates) -> verdict string."""
    try:
        import claude_judge as ck  # type: ignore
        fn = getattr(ck, "judge", None)
        if callable(fn):
            def _shared(new_fact, candidates):
                out = fn(new_fact, candidates, model=RECONCILE_MODEL)
                # shared judge may return the raw dict or a verdict string
                if isinstance(out, dict):
                    return _apply_guard(out, [c.get("id") for c in candidates])
                return str(out).upper()
            print("judge: memory-keeper/claude_judge.judge (shared)\n")
            return _shared
    except Exception:  # noqa: BLE001 — module absent or import-time env missing
        pass
    print("judge: inline (mirrors contract §6)\n")
    return _inline_judge


def main() -> None:
    cases = load_jsonl(CASES)
    if not cases:
        raise SystemExit(f"{CASES} has no rows")
    judge = _resolve_judge()

    labels = list(VERDICTS) + ["ERROR"]
    # confusion[expected][got]
    confusion = {exp: {got: 0 for got in labels} for exp in VERDICTS}
    correct = 0

    print(f"{'#':>2}  {'expect':<7}  {'got':<7}  note")
    print("-" * 60)
    for i, case in enumerate(cases, 1):
        expect = str(case["expect_verdict"]).upper()
        got = judge(case["new_fact"], case.get("candidates", []))
        if expect in confusion:
            confusion[expect][got if got in labels else "ERROR"] += 1
        if got == expect:
            correct += 1
        note = (case.get("note") or "")[:40]
        print(f"{i:>2}  {expect:<7}  {got:<7}  {note}")

    print("\n== confusion matrix (rows=expected, cols=predicted) ==")
    print(f"{'exp/got':<9}" + "".join(f"{c:>8}" for c in labels))
    for exp in VERDICTS:
        row = "".join(f"{confusion[exp][c]:>8}" for c in labels)
        print(f"{exp:<9}{row}")

    n = len(cases)
    acc = correct / n if n else 0.0
    print(f"\naccuracy = {acc:.3f}  ({correct}/{n})")

    floor = float(os.environ.get("EVAL_RECONCILE_FLOOR", "0.0"))
    sys.exit(0 if acc >= floor else 1)


if __name__ == "__main__":
    main()
