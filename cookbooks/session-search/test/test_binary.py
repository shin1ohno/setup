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
    path.write_text('#!/bin/sh\n[ -z "${EXECUTION_MARKER:-}" ] || echo executed >> "$EXECUTION_MARKER"\ncase "$1" in\n_buildinfo) echo \'' + info + "'; exit ${BUILDINFO_EXIT:-0};;\n*) echo fixture-rust;;\nesac\n")
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
        raise AssertionError(("expected exit %s containing %r; got %s" % (expected, contains, p.returncode), args, p.stdout, p.stderr))
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
        def invoke(mode, p=pins[0], sha=None, expected=0, contains=None, extra=None, destination=None):
            result = run(["/bin/bash", SCRIPT, mode, p, sha or sums[p], TARGET, destination or share], dict(env, **(extra or {})), expected, contains)
            leftovers = list(share.glob("bin/.ccs.*")) + list(share.glob(".binary-record.*"))
            assert not leftovers, "staging cleanup failed: " + repr(leftovers)
            return result
        invoke("check", expected=1)
        invoke("deploy"); invoke("check")
        print("PASS deploy + network-free check")
        before = (share / "DEPLOYED_BINARY").read_bytes()
        executed = work / "executed"
        invoke("deploy", pins[1], "0" * 64, 1, "sha256 mismatch", {"EXECUTION_MARKER": str(executed)})
        assert not executed.exists(), "download executed before sha256 verification"
        assert (share / "DEPLOYED_BINARY").read_bytes() == before
        print("N11 PASS: incorrect sha256 rejected; marker unchanged")
        path = share / "bin" / ("ccs-" + pins[0])
        good = path.read_bytes(); path.write_bytes(good + b"x")
        invoke("check", expected=1, contains="sha256 mismatch", extra={"EXECUTION_MARKER": str(executed)})
        assert not executed.exists(), "installed binary executed before sha256 verification"
        print("N11 PASS: one-byte artifact change rejected by check")
        path.write_bytes(good)
        path.chmod(0o700); invoke("check", expected=1, contains="mode"); path.chmod(0o755)
        original = work / "original"; path.rename(original); path.symlink_to(original)
        invoke("check", expected=1, contains="regular"); path.unlink(); original.rename(path)
        alias = work / "share-alias"; alias.symlink_to(share, target_is_directory=True)
        invoke("check", expected=1, contains="unsafe share directory", destination=alias)
        real_bin = work / "real-bin"; (share / "bin").rename(real_bin)
        (share / "bin").symlink_to(real_bin, target_is_directory=True)
        invoke("check", expected=1, contains="unsafe share directory")
        (share / "bin").unlink(); real_bin.rename(share / "bin")
        print("PASS both share and bin symlink defences")
        invoke("check", expected=1, contains="execution failed", extra={"BUILDINFO_EXIT": "9"})
        invoke("deploy", pins[1], expected=1, contains="execution failed", extra={"BUILDINFO_EXIT": "9"})
        assert (share / "DEPLOYED_BINARY").read_bytes() == before
        print("PASS buildinfo nonzero with valid JSON is rejected; staging removed")
        wrong_target = "x86_64-unknown-linux-gnu" if TARGET != "x86_64-unknown-linux-gnu" else "aarch64-unknown-linux-gnu"
        bad = release / pins[1] / ("ccs-" + TARGET)
        bad_sha = binary(bad, pins[1], wrong_target)
        invoke("deploy", pins[1], bad_sha, 1, "identity mismatch")
        assert (share / "DEPLOYED_BINARY").read_bytes() == before
        sums[pins[1]] = binary(bad, pins[1])
        print("PASS matching commit with wrong target is rejected")
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
        # Fail after mktemp for the record, independently of binary staging.
        real_mv = shutil.which("mv")
        (tools / "mv").write_text('#!/bin/sh\ncase "$2" in */.binary-record.*) exit 91;; esac\nexec "' + real_mv + '" "$@"\n')
        (tools / "mv").chmod(0o755)
        sums[pins[1]] = binary(bad, pins[1])
        invoke("deploy", pins[1], expected=1, contains="cannot place record")
        invoke("check", pins[2])
        print("PASS failed record placement cleans staging and preserves marker")
        print("OK deploy-binary: " + os.uname().sysname)


if __name__ == "__main__":
    main()
