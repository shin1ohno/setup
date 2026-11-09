"""Python oracle emitter for fake releases in the hermetic rollback test."""
import importlib.util
import json
import os
from pathlib import Path
import sys

repo = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("crosscheck", repo / "bin/lib/session-search-conformance.py")
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
server = Path(os.environ["SESSION_SEARCH_SERVER"])
runner, sr, header, vectors = gate.load(server, server / "conformance/session_redact_r1.jsonl")
for vector in vectors:
    if vector["op"] in gate.MASK_OPS:
        print(json.dumps({"id": vector["id"], "result": gate.reference(runner, sr, header, vector)}, ensure_ascii=True))
