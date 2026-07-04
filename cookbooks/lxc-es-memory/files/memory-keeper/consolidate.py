"""memory-keeper nightly consolidation (§6, run_kind=consolidate).

Runs once per night (launchd StartCalendarInterval 03:30) under the same
LaunchDaemon posture. Four phases:

  1. episode expiry: delete_by_query memory-episode where expires_at < now AND
     NOT promoted_to exists (promoted episodes are already copied, safe to drop).
  2. promotion: one `claude -p` pass over recent, un-promoted episodes proposes
     durable claims + supporting episode ids. Code-side corroboration gate
     (>=2 distinct provenance.session_id OR any source_class=user-stated) writes
     the claim as a RAW fact (source_class=promoted, derived_from=[episode_ids])
     so it flows through the standard reconcile pipeline; each supporting episode
     gets promoted_to set.
  3. near-dup: kNN self-scan on memory-fact; cosine >0.95 supersedes the older,
     0.90-0.95 is reported (log only).
  4. stats self-report doc to memory-stats.

Locking via fcntl.flock; exit 0 on contention. Stdlib only.
"""

from __future__ import annotations

import fcntl
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from es_client import ESClient, ESError, content_hash, cosine, now_iso  # noqa: E402
import voyage_client  # noqa: E402
import claude_judge  # noqa: E402


def _env(name, default):
    v = os.environ.get(name)
    return v if v not in (None, "") else default


FACT_INDEX = _env("FACT_INDEX", "memory-fact")
EPISODE_INDEX = _env("EPISODE_INDEX", "memory-episode")
STATS_INDEX = _env("STATS_INDEX", "memory-stats")
KEEPER_HOST = _env("KEEPER_HOST", "mini")
CONSOLIDATE_MODEL = _env("CONSOLIDATE_MODEL", "opus")
PROMOTE_WINDOW = int(_env("PROMOTE_WINDOW", "200"))
NEAR_DUP_LIMIT = int(_env("NEAR_DUP_LIMIT", "2000"))
PROMPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompts", "promote.md")

DUP_SUPERSEDE = 0.95
DUP_REPORT_LOW = 0.90


def _acquire_lock():
    state_dir = os.path.join(
        os.environ.get("HOME", "/Users/shin1ohno"), ".local", "state", "memory-keeper"
    )
    os.makedirs(state_dir, exist_ok=True)
    lock_path = os.path.join(state_dir, "consolidate.lock")
    lf = open(lock_path, "w")
    try:
        fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("consolidate: another instance holds the lock; exiting", file=sys.stderr)
        sys.exit(0)
    return lf


def _expire_episodes(es, now):
    body = {
        "query": {
            "bool": {
                "filter": [{"range": {"expires_at": {"lt": now}}}],
                "must_not": [{"exists": {"field": "promoted_to"}}],
            }
        }
    }
    res = es.delete_by_query(EPISODE_INDEX, body, refresh="true")
    return res.get("deleted", 0)


def _promote(es, now):
    body = {
        "size": PROMOTE_WINDOW,
        "sort": [{"provenance.written_at": {"order": "desc"}}],
        "query": {
            "bool": {
                "must_not": [
                    {"exists": {"field": "promoted_to"}},
                    {"exists": {"field": "superseded_by"}},
                ]
            }
        },
        "_source": ["content", "provenance", "tags", "entities"],
    }
    eps = es.search(EPISODE_INDEX, body)["hits"]["hits"]
    if not eps:
        return 0, 0

    ep_by_id = {h["_id"]: h for h in eps}
    payload = {
        "episodes": [
            {
                "id": h["_id"],
                "content": h.get("_source", {}).get("content", ""),
                "session_id": h.get("_source", {}).get("provenance", {}).get("session_id"),
                "source_class": h.get("_source", {}).get("provenance", {}).get("source_class"),
            }
            for h in eps
        ]
    }
    with open(PROMPT_PATH, "r", encoding="utf-8") as fh:
        template = fh.read()
    prompt = template.replace("{{PAYLOAD}}", json.dumps(payload, ensure_ascii=False))

    try:
        verdict = claude_judge.judge_json(prompt, CONSOLIDATE_MODEL, timeout=120, retries=1)
    except claude_judge.JudgeError as exc:
        print(f"consolidate: promote judge failed: {exc}", file=sys.stderr)
        return 0, 1

    candidates = verdict.get("candidates", [])
    if not isinstance(candidates, list):
        return 0, 1

    promoted = 0
    errors = 0
    for cand in candidates:
        cand = cand or {}
        claim = cand.get("claim")
        sup_raw = cand.get("supporting_episode_ids", []) or []
        sup_ids = [i for i in sup_raw if i in ep_by_id]
        if not claim or not sup_ids:
            continue

        sessions = set()
        user_stated = False
        for i in sup_ids:
            prov = ep_by_id[i].get("_source", {}).get("provenance", {}) or {}
            if prov.get("session_id"):
                sessions.add(prov["session_id"])
            if prov.get("source_class") == "user-stated":
                user_stated = True

        # corroboration gate: >=2 distinct sessions OR any user-stated support.
        if not (len(sessions) >= 2 or user_stated):
            continue

        try:
            emb = voyage_client.embed_documents([claim])[0]
        except voyage_client.VoyageUnavailable as exc:
            print(f"consolidate: voyage down during promotion: {exc}", file=sys.stderr)
            errors += 1
            break

        prov_new = {"agent": "memory-keeper", "source_class": "promoted", "written_at": now}
        fact_doc = {
            "content": claim,
            "embedding": emb,
            "memory_type": "fact",
            "tags": [],
            "entities": [],
            "provenance": prov_new,
            "reconcile_status": "raw",
            "content_hash": content_hash(claim),
            "derived_from": sup_ids,
            "use_count": 0,
            "last_used_at": now,
        }
        try:
            res = es.index_doc(FACT_INDEX, fact_doc, refresh="wait_for")
            new_id = res["_id"]
        except ESError as exc:
            print(f"consolidate: promote index failed: {exc}", file=sys.stderr)
            errors += 1
            continue

        for i in sup_ids:
            try:
                es.update(EPISODE_INDEX, i, {"promoted_to": new_id}, refresh="false")
            except ESError:
                errors += 1
        promoted += 1
        print(f"AUDIT promote new_id={new_id} from={','.join(sup_ids)}", file=sys.stderr)

    return promoted, errors


def _near_dup(es, now):
    body = {
        "size": NEAR_DUP_LIMIT,
        "query": {
            "bool": {
                "filter": [{"term": {"memory_type": "fact"}}],
                "must_not": [{"exists": {"field": "superseded_by"}}],
            }
        },
        "_source": ["content", "embedding", "provenance"],
    }
    facts = es.search(FACT_INDEX, body)["hits"]["hits"]
    superseded_now = set()
    superseded_count = 0
    errors = 0
    reports = []

    # ES 9.x excludes dense_vector from _source, so the stored vectors are not
    # retrievable. Re-embed every fact's content once (batched) into an
    # id -> vector map; near-dup then computes cosine locally from the map.
    _pairs = [(h["_id"], (h.get("_source", {}).get("content") or "").strip()) for h in facts]
    _texts = [c for _, c in _pairs if c]
    vmap = {}
    if _texts:
        try:
            _vecs = voyage_client.embed_documents(_texts)
        except voyage_client.VoyageUnavailable as exc:
            print(f"consolidate: voyage down for near-dup re-embed: {exc}; skipping near-dup", file=sys.stderr)
            return 0, 1
        _i = 0
        for _fid, _c in _pairs:
            if _c:
                vmap[_fid] = _vecs[_i]
                _i += 1

    for h in facts:
        fid = h["_id"]
        if fid in superseded_now:
            continue
        emb = vmap.get(fid)
        if not emb:
            continue
        knn_body = {
            "knn": {
                "field": "embedding",
                "query_vector": emb,
                "k": 6,
                "num_candidates": 100,
                "filter": {"bool": {"must_not": [{"exists": {"field": "superseded_by"}}]}},
            },
            "size": 6,
            "_source": ["content", "embedding", "provenance"],
        }
        try:
            neighbors = es.search(FACT_INDEX, knn_body)["hits"]["hits"]
        except ESError:
            errors += 1
            continue
        f_ts = h.get("_source", {}).get("provenance", {}).get("written_at", "")
        for n in neighbors:
            nid = n["_id"]
            if nid == fid or nid in superseded_now:
                continue
            nemb = vmap.get(nid)
            if not nemb:
                continue
            cos = cosine(emb, nemb)
            if cos > DUP_SUPERSEDE:
                n_ts = n.get("_source", {}).get("provenance", {}).get("written_at", "")
                older, newer = (fid, nid) if f_ts <= n_ts else (nid, fid)
                try:
                    es.update(
                        FACT_INDEX,
                        older,
                        {"superseded_by": newer, "superseded_at": now, "reconcile_status": "reconciled"},
                        refresh="false",
                    )
                    superseded_now.add(older)
                    superseded_count += 1
                    print(f"AUDIT near-dup supersede older={older} by={newer} cos={cos:.4f}", file=sys.stderr)
                except ESError:
                    errors += 1
                if older == fid:
                    break
            elif DUP_REPORT_LOW <= cos <= DUP_SUPERSEDE:
                reports.append((fid, nid, round(cos, 4)))

    if reports:
        print(
            f"consolidate: {len(reports)} near-dup pairs in 0.90-0.95 band (report only): {reports[:20]}",
            file=sys.stderr,
        )
    return superseded_count, errors


def main():
    t0 = time.monotonic()
    _lock = _acquire_lock()  # noqa: F841 (held for process lifetime)
    es = ESClient()

    errors = 0
    try:
        expired = _expire_episodes(es, now_iso())
    except ESError as exc:
        print(f"consolidate: expire failed: {exc}", file=sys.stderr)
        expired = 0
        errors += 1

    try:
        promoted, perr = _promote(es, now_iso())
        errors += perr
    except ESError as exc:
        print(f"consolidate: promote failed: {exc}", file=sys.stderr)
        promoted = 0
        errors += 1

    try:
        near_dup_superseded, nerr = _near_dup(es, now_iso())
        errors += nerr
    except ESError as exc:
        print(f"consolidate: near-dup failed: {exc}", file=sys.stderr)
        near_dup_superseded = 0
        errors += 1

    stats_doc = {
        "written_at": now_iso(),
        "host": KEEPER_HOST,
        "run_kind": "consolidate",
        "expired_deleted": expired,
        "promoted_total": promoted,
        "superseded_total": near_dup_superseded,
        "errors": errors,
        "loop_lag_ms": (time.monotonic() - t0) * 1000.0,
    }
    try:
        es.index_doc(STATS_INDEX, stats_doc, refresh="false")
    except ESError as exc:
        print(f"consolidate: stats write failed: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
