"""Check the actual Python-era function and both callers, including N9."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["all", "crates", "cli", "flat", "vendor", "n9"], default="all")
    case = parser.parse_args().case
    with tempfile.TemporaryDirectory(prefix="ccs-python-tree-") as tmp:
        work = Path(tmp); origin = work / "origin"; origin.mkdir()
        base = work / "files"
        shutil.copytree(REPO / "cookbooks/lxc-es-memory/files", base)
        server = base / "memory-mcp"
        pinfile = work / "session-search.pin"; rustfile = work / "session-search.rust"
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_COUNT="0",
                   PYTHONDONTWRITEBYTECODE="1", SESSION_SEARCH_ORIGIN=str(origin),
                   SESSION_SEARCH_PIN_FILE=str(pinfile), SESSION_SEARCH_RUST_FILE=str(rustfile),
                   SESSION_SEARCH_SERVER=str(server))
        def run(args, code=0, reason=None):
            p = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True)
            assert p.returncode == code and (not reason or reason in p.stdout+p.stderr), (args, reason, p.returncode, p.stdout, p.stderr)
            return p.stdout+p.stderr
        def git(*args):
            return run(["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-C", origin, *args]).strip()
        git("init", "-qb", "main")
        with tarfile.open(HERE / "fixtures/python-era.tar.gz") as archive: archive.extractall(origin, filter="data")
        git("add", "-A"); git("commit", "-qm", "fixture: original Python tree")
        initial = git("rev-parse", "HEAD")
        def set_pin():
            pin = git("rev-parse", "HEAD")
            pinfile.write_text(pin+"\n"); rustfile.write_text("pin "+pin+"\n")
            return pin
        def direct(pin, code=0, reason=None):
            return run(["/bin/bash", "-c", 'source "$1"; ss_python_tree "$2" "$3" "$4"', "tree-check",
                        REPO / "bin/lib/session-search-era.sh", origin, pin, server], code, reason)
        direct(set_pin())
        for label,reason in [("crates","Python-era pin contains crates/"), ("cli","no ccs/cli.py"),
                             ("flat","ccs/ is not flat"), ("vendor","differs from server"), ("n9","source_blob mismatch")]:
            if case not in ("all",label): continue
            git("reset", "--hard", initial); git("clean", "-fd")
            if label=="crates":
                (origin/"crates").mkdir(); (origin/"crates/not-a-boundary.rs").write_text("// fixture\n")
            elif label=="cli": (origin/"ccs/cli.py").unlink()
            elif label=="flat":
                (origin/"ccs/nested").mkdir(); (origin/"ccs/nested/module.py").write_text("# fixture\n")
            else:
                source=origin/"vendor/memory-mcp/session_redact.py"
                source.write_bytes(source.read_bytes()+b"\n")
                if label=="n9": shutil.copy(source,server/"session_redact.py")
            git("add", "-A"); git("commit", "-qm", "fixture: "+label)
            pin=set_pin()
            if label=="n9":
                # Both copies agree, so only the unchanged corpus source_blob fails.
                direct(pin)
                run(["/bin/bash", REPO/"cookbooks/session-search/test/check-pin.sh",pinfile])
                output=run(["/bin/bash", REPO/"bin/check-memory-v2-manifest",base],1,reason)
                assert "byte-identical" in output and "ERA python" in output
            else:
                direct(pin,1,reason)
                run(["/bin/bash",REPO/"cookbooks/session-search/test/check-pin.sh",pinfile],1,reason)
                output=run(["/bin/bash",REPO/"bin/check-memory-v2-manifest",base],1,reason)
            print("PASS Python tree guard",label,flush=True)
            print("\n".join(line for line in output.splitlines() if "FAIL" in line),flush=True)
        print("OK Python tree and N9 manifest path")


if __name__ == "__main__": main()
