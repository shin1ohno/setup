"""Hermetic deployment gates with real script execution and receiving state."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "files/deploy-binary.sh"
TARGET = "aarch64-apple-darwin" if os.uname().sysname == "Darwin" else "x86_64-unknown-linux-gnu"


def binary(path, pin, target=TARGET):
    info = json.dumps(dict(version="0.2.0", commit=pin, target=target, redact_version="r1"), separators=(",", ":"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\ncase "$1" in\n_buildinfo) echo \'' + info + "';;\n*) echo fixture-rust;;\nesac\n")
    path.chmod(0o755)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def curl_fixture(path):
    path.write_text('''#!/bin/bash
set -eu
url='' out=''
while [ "$#" -gt 0 ]; do
  case "$1" in https://*) url=$1 ;; -o) shift; out=$1 ;; esac
  shift
done
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
[ -n "$url" ]
printf '%s\n' "$url" >> "$FIXTURE_RELEASE/downloads"
suffix=${url##*/download/ccs-}
if [ -n "$out" ]; then cp "$FIXTURE_RELEASE/$suffix" "$out"; else cat "$FIXTURE_RELEASE/$suffix"; fi
''')
    path.chmod(0o755)


def run(args, env, expected=0, contains=None):
    p = subprocess.run([str(a) for a in args], env=env, capture_output=True, text=True)
    if p.returncode != expected or (contains and contains not in p.stdout + p.stderr):
        raise AssertionError((args, p.returncode, p.stdout, p.stderr))
    if expected:
        print((p.stdout + p.stderr).strip())
    return p


def main():
    with tempfile.TemporaryDirectory(prefix="ccs-binary-") as work:
        work = Path(work); share = work / "share"; tools = work / "tools"; tools.mkdir()
        release = work / "release"; release.mkdir()
        curl_fixture(tools / "curl")
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], FIXTURE_RELEASE=str(release))
        pins = [str(i) * 40 for i in (1, 2, 3)]
        sums = {p: binary(release / p / ("ccs-" + TARGET), p) for p in pins}
        def invoke(mode, p=pins[0], sha=None, expected=0, contains=None, extra=None):
            return run(["/bin/bash", SCRIPT, mode, p, sha or sums[p], TARGET, share], dict(env, **(extra or {})), expected, contains)
        invoke("check", expected=1)
        invoke("deploy"); invoke("check")
        print("PASS deploy + network-free check")
        before = (share / "DEPLOYED_BINARY").read_bytes()
        invoke("deploy", pins[1], "0" * 64, 1, "sha256 mismatch")
        assert (share / "DEPLOYED_BINARY").read_bytes() == before
        print("N11 PASS: incorrect sha256 rejected; marker unchanged")
        path = share / "bin" / ("ccs-" + pins[0])
        good = path.read_bytes(); path.write_bytes(good + b"x")
        invoke("check", expected=1, contains="sha256 mismatch")
        print("N11 PASS: one-byte artifact change rejected by check")
        path.write_bytes(good)
        path.chmod(0o700); invoke("check", expected=1, contains="mode"); path.chmod(0o755)
        original = work / "original"; path.rename(original); path.symlink_to(original)
        invoke("check", expected=1, contains="regular"); path.unlink(); original.rename(path)
        invoke("deploy", pins[1], extra={"FAIL_DOWNLOAD": "1"}, contains="WARN")
        assert (share / "DEPLOYED_BINARY").read_bytes() == before
        print("PASS failed download preserves receiving state")
        invoke("deploy", pins[1]); invoke("check", pins[1])
        invoke("deploy", pins[0], extra={"FAIL_DOWNLOAD": "1"}); invoke("check", pins[0])
        assert (share / "bin" / ("ccs-" + pins[1])).exists()
        print("PASS X -> Y -> X uses retained binary without download")
        invoke("deploy", pins[2])
        assert not (share / "bin" / ("ccs-" + pins[1])).exists()
        assert (share / "bin" / ("ccs-" + pins[0])).exists()
        print("PASS only current and previous pins retained")
        bad = release / pins[1] / ("ccs-" + TARGET)
        bad_sha = binary(bad, pins[2])
        invoke("deploy", pins[1], bad_sha, 1, "identity mismatch")
        invoke("check", pins[2])
        print("PASS wrong embedded commit rejected; current binary still verifies")
        print("OK deploy-binary: " + os.uname().sysname)


if __name__ == "__main__":
    main()
