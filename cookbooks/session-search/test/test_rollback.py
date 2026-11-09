"""RT1: actual archive tree, fake origin/release, real recipe and CI gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

from test_binary import curl_fixture

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
TARGETS = ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "aarch64-apple-darwin"]
NATIVE = "aarch64-apple-darwin" if os.uname().sysname == "Darwin" else ("aarch64-unknown-linux-gnu" if os.uname().machine == "aarch64" else TARGETS[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["all", "cache", "python-gate", "manifest-guards", "manifest-corpus-redact", "manifest-corpus-codex", "manifest-ruleset", "manifest-commit", "manifest-target", "manifest-emit", "manifest-conformance-redact", "manifest-conformance-codex", "manifest-conformance-emit"], default="all")
    selected = parser.parse_args().case
    with tempfile.TemporaryDirectory(prefix="ccs-rollback-") as tmp:
        work = Path(tmp); origin = work / "origin"; origin.mkdir()
        home = work / "home"; home.mkdir(); (home / ".fixture-home").touch()
        recipe = work / "recipe"; shutil.copytree(HERE.parent, recipe)
        release = work / "release"; release.mkdir()
        tools = work / "tools"; tools.mkdir(); curl_fixture(tools / "curl")
        env = dict(os.environ, HOME=str(home), PYTHONDONTWRITEBYTECODE="1", GIT_CONFIG_GLOBAL="/dev/null",
                   GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_COUNT="0", GIT_TERMINAL_PROMPT="0",
                   PATH=str(tools) + os.pathsep + os.environ["PATH"], SESSION_SEARCH_ORIGIN=str(origin),
                   SESSION_SEARCH_SERVER=str(REPO / "cookbooks/lxc-es-memory/files/memory-mcp"),
                   FIXTURE_RELEASE=str(release), FIXTURE_EMITTER=str(HERE / "fixture_emit.py"))
        # Resolve tool-manager shims before changing HOME.
        python = subprocess.check_output(["python3", "-I", "-c", "import sys; print(sys.executable)"], text=True).strip()
        ruby = subprocess.check_output(["ruby", "-rrbconfig", "-e", "puts RbConfig.ruby"], text=True).strip()
        env["PATH"] = str(tools) + os.pathsep + str(Path(python).parent) + os.pathsep + str(Path(ruby).parent) + os.pathsep + os.environ["PATH"]
        env["FIXTURE_PYTHON"] = python

        def call(argv, code=0, contains=None, extra=None):
            p = subprocess.run([str(a) for a in argv], env=dict(env, **(extra or {})), capture_output=True, text=True)
            if p.returncode != code or (contains and contains not in p.stdout + p.stderr):
                raise AssertionError((argv, p.returncode, p.stdout, p.stderr))
            if code:
                print("EXPECTED FAILURE:", contains, "exit", p.returncode)
                print("\n".join(line for line in (p.stdout + p.stderr).splitlines() if "FAIL" in line or "ERROR" in line or "mismatch" in line))
            return p.stdout

        def git(*args):
            return call(["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-C", origin, *args]).strip()

        git("init", "-q", "-b", "main")
        with tarfile.open(HERE / "fixtures/python-era.tar.gz") as archive:
            archive.extractall(origin, filter="data")
        git("add", "-A")
        assert git("write-tree") == "f4a278a13411d08dc50843d3cdb9f3385d722ed1"
        git("commit", "-qm", "fixture: exact Python-era tree")
        old = git("rev-parse", "HEAD")
        (origin / "fixture-note").write_text("second Python pin\n")
        git("add", "-A"); git("commit", "-qm", "fixture: Python revision")
        py = git("rev-parse", "HEAD")
        (origin / "crates/ccs").mkdir(parents=True)
        (origin / "crates/ccs/Cargo.toml").write_text("# Rust era boundary fixture\n")
        shutil.copytree(Path(env["SESSION_SEARCH_SERVER"]) / "conformance", origin / "vendor/memory-mcp/conformance")
        git("add", "-A"); git("commit", "-qm", "fixture: Rust boundary")
        x = git("rev-parse", "HEAD")
        (origin / "fixture-note").write_text("second Rust pin\n")
        git("add", "-A"); git("commit", "-qm", "fixture: second Rust pin")
        y = git("rev-parse", "HEAD")
        sums = {}
        # The test doubles replace only network/provenance services. Their CLI
        # insists on all policy arguments, and rejects deliberate bad claims.
        gh = tools / "gh"
        gh.write_text('''#!/bin/bash
set -eu
if [ "${3:-}" = --help ]; then echo --source-digest; exit 0; fi
[ "$1 $2" = 'attestation verify' ] || exit 91
shift 3
repo='' workflow='' source='' signer='' ref=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) shift; repo=$1 ;; --signer-workflow) shift; workflow=$1 ;;
    --source-digest) shift; source=$1 ;; --signer-digest) shift; signer=$1 ;;
    --source-ref) shift; ref=$1 ;; --deny-self-hosted-runners) ;; *) exit 92 ;;
  esac
  shift
done
[ "$repo" = shin1ohno/session-search ] && [ "$workflow" = shin1ohno/session-search/.github/workflows/release.yml ]
[ "$source" = "$signer" ] && [ "$ref" = refs/heads/main ]
[ "${BAD_PROVENANCE:-0}" = 0 ] || exit 93
echo 'fixture provenance verified'
'''); gh.chmod(0o755)
        def make_release(pin, **overrides):
            sums[pin] = {}
            for target in TARGETS:
                binary = release / pin / ("ccs-" + target); binary.parent.mkdir(exist_ok=True)
                fields = dict(version="0.2.0", commit=pin, target=target, redact_version="r1")
                fields.update(overrides)
                info = json.dumps(fields, separators=(",", ":"))
                binary.write_text('#!/bin/sh\ncase "$1" in\n_buildinfo) echo \'' + info + '''';;
_conformance)
mode=$2
[ "${3:-}" != --emit ] || mode=emit
if [ "${FIXTURE_FAIL_CONFORMANCE:-}" = "$mode" ]; then
  echo "fixture conformance $mode rejected" >&2
  exit 42
fi
if [ "${3:-}" = --emit ]; then
  [ "${FIXTURE_EMPTY_EMIT:-0}" = 0 ] || exit 0
  exec "$FIXTURE_PYTHON" "$FIXTURE_EMITTER"
fi ;;
*) echo fixture-rust ;;
esac
'''); binary.chmod(0o755)
                sums[pin][target] = hashlib.sha256(binary.read_bytes()).hexdigest()
            (release / pin / "SHA256SUMS").write_text("".join("%s  ccs-%s\n" % (sums[pin][t], t) for t in TARGETS))
        for pin in (x, y): make_release(pin)
        pinfile = recipe / "session-search.pin"; rustfile = recipe / "session-search.rust"
        env.update(SESSION_SEARCH_PIN_FILE=str(pinfile), SESSION_SEARCH_RUST_FILE=str(rustfile))

        def manifest(pin, hosts=(), hashpin=None):
            pinfile.write_text(pin + "\n")
            chosen = hashpin or pin
            rustfile.write_text("pin " + chosen + "\n" + "".join("host " + h + "\n" for h in hosts) +
                                "".join("sha256 %s %s\n" % (sha, t) for t, sha in sums.get(chosen, {}).items()))

        def checks(label, code=0, contains=None):
            print("BEGIN RT1 manifest + pin:", label, flush=True)
            print(call(["/bin/bash", REPO / "cookbooks/session-search/test/check-pin.sh", pinfile], code, contains), flush=True)
            print(call(["/bin/bash", REPO / "bin/check-memory-v2-manifest"], code, contains), flush=True)
            print("PASS RT1 manifest + pin:", label)

        def converge(code=0, contains=None, extra=None):
            return call([ruby, HERE / "render-recipe.rb", recipe / "common.rb", home], code, contains, extra)

        launcher = home / ".local/bin/ccs"
        def launch(want, pin=None):
            output = call([launcher, "--version"])
            assert want in output, output
            if pin:
                assert "ccs-" + pin in launcher.read_text(), "launcher points at a different pin"
                info = json.loads(call([launcher, "_buildinfo"]))
                assert info["commit"] == pin and info["target"] == NATIVE, "launcher executes a different pin"

        def manifest_guards(selection="guards"):
            def verify(label, code=0, reason=None, extra=None):
                print("BEGIN manifest guard", label, flush=True)
                output = call(["/bin/bash", REPO / "bin/check-memory-v2-manifest"], code, reason, extra)
                print("\n".join(line for line in output.splitlines() if "FAIL" in line or "PASS cross-check" in line), flush=True)
                print("PASS manifest guard", label, flush=True)
            if selection == "guards":
                manifest(x); verify("baseline")
            # Change only serialized corpus bytes at the pin, keeping valid JSON
            # and the vector checksum; all other gates have valid inputs.
            for suite in ("redact", "codex"):
                if selection not in ("guards", "corpus-" + suite): continue
                corpus = origin / "vendor/memory-mcp/conformance" / ("session_redact_r1.jsonl" if suite == "redact" else "session_codex_v1.jsonl")
                original = corpus.read_bytes(); corpus.write_bytes(b" " + original)
                git("add", "-A"); git("commit", "-qm", "fixture: different corpus bytes")
                mismatch = git("rev-parse", "HEAD"); make_release(mismatch); manifest(mismatch)
                verify("corpus OID " + suite, 1, "pinned corpus differs from server")
                corpus.write_bytes(original); git("add", "-A"); git("commit", "-qm", "fixture: restore corpus")
            for label, overrides, reason in [
                ("ruleset", {"redact_version": "unsupported-fixture"}, "unsupported redact_version"),
                ("commit", {"commit": "0" * 40}, "build identity mismatch"),
                ("target", {"target": "unsupported-fixture"}, "build identity mismatch"),
            ]:
                if selection not in ("guards", label): continue
                make_release(x, **overrides); manifest(x); verify(label, 1, reason)
            make_release(x); manifest(x)
            for mode in ("redact", "codex", "emit"):
                if selection not in ("guards", "conformance-" + mode): continue
                reason = ("redact: artifact conformance emit failed" if mode == "emit"
                          else mode + ": artifact conformance failed")
                verify("conformance " + mode, 1, reason, {"FIXTURE_FAIL_CONFORMANCE": mode})
            if selection in ("guards", "emit"):
                verify("cross-check invocation", 1, "missing or extra emit row", {"FIXTURE_EMPTY_EMIT": "1"})
            print("OK manifest guards 1, 4, 5, 6 and build identity", flush=True)

        def cache_case():
            manifest(x, ["air"]); converge(); launch("fixture-rust", x)
            manifest(y, ["air"]); converge(); launch("fixture-rust", y)
            manifest(x, ["air"]); converge(extra={"FAIL_DOWNLOAD": "1"}); launch("fixture-rust", x)
            print("PASS RT1 cache rollback launcher executes X", flush=True)

        def python_gate_case():
            manifest(x, ["air"]); converge(); launch("fixture-rust", x)
            share = home / ".local/share/session-search"
            marker = share / "DEPLOYED_BINARY"
            before_marker = marker.read_bytes(); before_launcher = launcher.read_bytes()
            # y has a valid available binary, but its Python tree cannot be fetched.
            manifest(y, ["air"])
            converge(extra={"SESSION_SEARCH_ORIGIN": str(work / "missing-origin")})
            assert marker.read_bytes() == before_marker, "binary deployed despite failed Python gate"
            assert not (share / "bin" / ("ccs-" + y)).exists(), "binary placement ran despite Python failure"
            assert launcher.read_bytes() == before_launcher, "failed Python deployment changed launcher"
            launch("fixture-rust", x)
            print("PASS binary placement waits for Python deployment", flush=True)

        if selected.startswith("manifest-"):
            manifest_guards(selected[len("manifest-"):]); return
        if selected == "cache":
            cache_case(); return
        if selected == "python-gate":
            python_gate_case(); return
        # Run the guard on a fresh share so y cannot hit a previously deployed cache.
        python_gate_case()

        manifest(py); converge(); launch("ccs 0.2.0"); checks("Python")
        manifest(x, ["air"]); converge(); launch("fixture-rust", x); checks("Rust X")
        manifest(x); converge(extra={"FAIL_DOWNLOAD": "1"}); launch("ccs 0.2.0"); checks("engine off")
        manifest(old); converge(); launch("ccs 0.2.0"); checks("old Python pin revert")
        manifest(x, ["air"]); converge(); launch("fixture-rust", x)
        manifest(y, ["air"]); converge(); launch("fixture-rust", y); checks("Rust Y")
        manifest(x, ["air"]); converge(extra={"FAIL_DOWNLOAD": "1"}); launch("fixture-rust", x); checks("Rust X cache rollback")
        before = launcher.read_bytes()
        manifest(old)
        # New fixture share's source remote is unavailable, forcing Python fetch WARN.
        converge(extra={"SESSION_SEARCH_ORIGIN": str(work / "missing-origin")})
        assert launcher.read_bytes() == before; launch("fixture-rust"); checks("fetch failure desired Python pin")
        manifest(y, ["air"])
        bad_manifest = rustfile.read_text().replace(sums[y][NATIVE], "0" * 64)
        rustfile.write_text(bad_manifest)
        converge(1, "sha256 mismatch"); assert launcher.read_bytes() == before; launch("fixture-rust")
        checks("wrong artifact hash", 1, "sha256 mismatch")
        manifest(x, ["air"], y)
        assert "ENGINE python" in converge(); launch("ccs 0.2.0")
        checks("host pin mismatch", 1, "pin mismatch")
        manifest(x, ["air"]); converge(); launch("fixture-rust")
        # N17: all three spoofing forms must fail both real check entrypoints.
        shutil.rmtree(origin / "crates")
        git("add", "-A"); git("commit", "-qm", "fixture: deleted Rust directory")
        deleted = git("rev-parse", "HEAD")
        manifest(deleted); checks("N17 deleted crates descendant", 1, "missing sha256")
        manifest(py, ["air"]); checks("N17 Python pin with host", 1, "missing sha256")
        rustfile.write_text(rustfile.read_text().rstrip("\n"))
        checks("Python pin with unterminated final host record", 1, "missing sha256")
        git("checkout", "-qb", "side", py)
        (origin / "side-only").touch(); git("add", "-A"); git("commit", "-qm", "fixture: unmerged")
        side = git("rev-parse", "HEAD"); git("checkout", "-q", "main")
        manifest(side); checks("N17 unmerged pin", 1, "not an ancestor")
        git("merge", "--no-ff", "-qm", "fixture: merged side history", "side")
        manifest(side); checks("merged side is not a strict boundary ancestor", 1, "missing sha256")
        shutil.rmtree(origin / "ccs")
        git("add", "-A"); git("commit", "-qm", "fixture: no Python package")
        no_python = git("rev-parse", "HEAD")
        manifest(no_python)
        before = launcher.read_bytes()
        converge(1, "no ccs/ files"); assert launcher.read_bytes() == before; launch("fixture-rust")
        checks("no Python tree", 1, "missing sha256")
        # Provenance failures are not executable-content failures.
        manifest(x)
        for claim in ("workflow", "commit", "digest"):
            call(["/bin/bash", REPO / "cookbooks/session-search/test/check-pin.sh", pinfile], 1,
                 "provenance mismatch", {"BAD_PROVENANCE": claim})
            print("PASS negative provenance:", claim)
        # Run the real bump command in a separate clean repository. It must
        # create one commit containing the two related pin files.
        bump_repo = work / "bump-repo"
        for rel in ("bin/bump-session-search", "bin/lib/session-search-era.sh", "bin/lib/session-search-artifact.sh",
                    "cookbooks/session-search/test/check-pin.sh"):
            destination = bump_repo / rel; destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / rel, destination)
        bump_cb = bump_repo / "cookbooks/session-search"
        (bump_cb / "session-search.pin").write_text(py + "\n")
        (bump_cb / "session-search.rust").write_text("pin " + py + "\n")
        def bg(*args):
            return call(["git", "-C", bump_repo, *args]).strip()
        bg("init", "-q", "-b", "fixture")
        bg("config", "user.name", "fixture"); bg("config", "user.email", "fixture@example.invalid")
        bg("config", "commit.gpgsign", "false")
        bg("add", "-A"); bg("commit", "-qm", "fixture: bump baseline")
        # Do not inherit the rollback recipe's override path into this command.
        call([python, bump_repo / "bin/bump-session-search", x, "--hosts", "air"], extra={"SESSION_SEARCH_RUST_FILE": ""})
        assert set(bg("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines()) == {
            "cookbooks/session-search/session-search.pin", "cookbooks/session-search/session-search.rust"}
        assert (bump_cb / "session-search.pin").read_text() == x + "\n"
        bump_manifest = bump_cb / "session-search.rust"
        bump_manifest.write_text(bump_manifest.read_text().replace("host air", "host\t  air"))
        bg("add", "-A"); bg("commit", "-qm", "fixture: alternate valid manifest whitespace")
        call([python, bump_repo / "bin/bump-session-search", "--engine-off", "air"])
        assert bg("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD") == "cookbooks/session-search/session-search.rust"
        assert "host " not in (bump_cb / "session-search.rust").read_text()
        print("PASS bump command commits pin/hashes together; engine-off changes only hosts")
        # N9 and N10 use copies of authoritative server files; no vendor edits.
        manifest(py)
        base = work / "server-copy"; shutil.copytree(REPO / "cookbooks/lxc-es-memory/files", base)
        sr = base / "memory-mcp/session_redact.py"; original = sr.read_bytes(); sr.write_bytes(original + b"\n")
        call([python, "-B", "-I", base / "memory-mcp/test_session_redact_conformance.py"], 1, "source_blob mismatch")
        print("N9 PASS source edit rejected")
        sr.write_bytes(original)
        corpus = base / "memory-mcp/conformance/session_redact_r1.jsonl"
        corpus.write_bytes(b"\n".join(corpus.read_bytes().splitlines()[:100]) + b"\n")
        call([python, "-B", "-I", base / "memory-mcp/test_session_redact_conformance.py"], 1, "vector count mismatch")
        print("N10 PASS truncated corpus rejected")
        manifest_guards()
        print("OK RT1 rollback + manifest: " + os.uname().sysname)


if __name__ == "__main__":
    main()
