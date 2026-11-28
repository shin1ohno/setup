"""Hermetic tests for the ai-memory binary track (ADR 0013 Decision 8).

Two parts, both without network or root:
  recipe  default.rb is evaluated by render-recipe.rb. An empty or missing
          ai-memory-bin.pin must declare exactly the resources of the source-only
          recipe; a valid pin adds the binary resources in the converge order of
          the plan (stage, place, activate, unit, restart); a malformed pin
          raises at compile time.
  script  files/ai-memory-bin.sh runs for real against a fixture release (a curl
          stand-in) and a systemctl stand-in that starts real processes, so the
          receiving state (files, links, /proc/<pid>/exe) is what is checked.
          The fault cases are the plan's 4.4 item 3: a wrong sha256, a missing
          tag, and a converge interrupted after activate and before the restart.

Usage: python3 cookbooks/lxc-es-memory/test/test_ai_memory_bin.py   (Linux)
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
COOKBOOK = HERE.parent
SCRIPT = COOKBOOK / "files/ai-memory-bin.sh"
RENDER = HERE / "render-recipe.rb"
PIN = (COOKBOOK / "files/ai-memory.pin").read_text().strip()
NAME = "ai-memory-noop"
UNIT = "ai-memory-noop.service"
# A copy of bash stands in for the binary: it answers --version, stays running as
# itself (`-c "kill -STOP $$"`), and does not dispatch on argv[0] the way a
# multicall coreutils (uutils) sleep does.
BASH = os.path.realpath(shutil.which("bash"))
PARK = ["-c", "kill -STOP $$"]
failures = 0


def check(cond, label):
    global failures
    print(("PASS  " if cond else "FAIL  ") + label)
    if not cond:
        failures += 1


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# --- recipe -----------------------------------------------------------------

def render(files_dir):
    p = subprocess.run(["ruby", str(RENDER), str(COOKBOOK / "default.rb"), str(files_dir)],
                       capture_output=True, text=True)
    return p.returncode, [json.loads(line) for line in p.stdout.splitlines()], p.stderr


def recipe_tests(work):
    def files(bin_pin):
        d = Path(tempfile.mkdtemp(dir=work))
        (d / "ai-memory.pin").write_text(PIN + "\n")
        if bin_pin is not None:
            (d / "ai-memory-bin.pin").write_text(bin_pin)
        return d

    rc_missing, missing, err = render(files(None))
    check(rc_missing == 0 and len(missing) > 40, "recipe renders with no ai-memory-bin.pin (%d resources) %s" % (len(missing), err.strip()))
    for label, body in (("empty", ""), ("blank lines only", "\n \n")):
        rc, got, err = render(files(body))
        check(rc == 0 and got == missing, "an %s ai-memory-bin.pin declares the same resources as a missing one" % label)
    text = json.dumps(missing)
    check(all(word not in text for word in ("ai-memory-bin.sh", "ai-memory binaries", NAME)),
          "an inactive pin declares no binary resource and stages no binary unit")
    # The real file in the tree is the inactive form.
    rc, real, _ = render(COOKBOOK / "files")
    check(rc == 0 and real == missing, "files/ai-memory-bin.pin in the tree is inactive")

    sha = "a" * 64
    rc, active, err = render(files("source_sha=%s\n%s %s\n" % (PIN, NAME, sha)))
    check(rc == 0, "a valid pin renders " + err.strip())
    names = [(r["type"], r["name"]) for r in active]

    def at(kind, name):
        return names.index((kind, name)) if (kind, name) in names else -1
    order = [at("remote_file", "/opt/es-memory/ai-memory-bin.sh"),
             at("execute", "stage ai-memory binaries"),
             at("execute", "place ai-memory at the pinned SHA"),
             at("execute", "activate ai-memory binaries"),
             at("systemd_unit", "memory-v2-proxy.service"),
             at("systemd_unit", UNIT),
             at("execute", "restart units running a stale ai-memory binary")]
    check(-1 not in order and order == sorted(order), "converge order is script, stage, place, activate, units, restart: %s" % order)
    stage = active[order[1]]["attrs"]
    check("stage %s /opt/es-memory %s=%s" % (PIN, NAME, sha) in stage["command"]
          and "check-staged" in stage["not_if"], "stage passes the pinned sha256 and is guarded by check-staged")
    place = active[order[2]]["attrs"]["command"]
    check("place systemd/%s /root/setup-root/es-memory/%s" % (UNIT, UNIT) in place,
          "the source placement stages the binary's unit from the checkout")
    restart = active[order[6]]["attrs"]
    check("%s=%s" % (UNIT, NAME) in restart["command"] and " stale " in restart["only_if"],
          "the restart is guarded by the stale check, not by a notify")
    others = [r for r in active if r["name"] not in (
        "/opt/es-memory/ai-memory-bin.sh", "stage ai-memory binaries", "activate ai-memory binaries",
        UNIT, "restart units running a stale ai-memory binary")]
    base = [r for r in missing]
    for r in (others, base):
        for x in r:
            if x["name"] == "place ai-memory at the pinned SHA":
                x["attrs"] = dict(x["attrs"], command="<compared above>", not_if="<compared above>")
    check(others == base, "an active pin changes no other resource")

    bad = {
        "source line missing": "%s %s\n" % (NAME, sha),
        "source_sha differs from ai-memory.pin": "source_sha=%s\n%s %s\n" % ("b" * 40, NAME, sha),
        "no binary line": "source_sha=%s\n" % PIN,
        "short sha256": "source_sha=%s\n%s %s\n" % (PIN, NAME, "a" * 63),
        "duplicate name": "source_sha=%s\n%s %s\n%s %s\n" % (PIN, NAME, sha, NAME, sha),
        "name without a unit": "source_sha=%s\nai-memory-server %s\n" % (PIN, sha),
        "name outside ai-memory-[a-z-]+": "source_sha=%s\nnoop %s\n" % (PIN, sha),
    }
    for label, body in bad.items():
        rc, _, err = render(files(body))
        check(rc != 0 and "ai-memory-bin.pin" in err, "a pin with %s raises at compile time" % label)


# --- script -----------------------------------------------------------------

CURL = r'''#!/bin/bash
url='' out=''
while [ "$#" -gt 0 ]; do
  case "$1" in https://*) url=$1 ;; -o) shift; out=$1 ;; esac
  shift
done
printf '%s\n' "$url" >> "$FIXTURE_RELEASE/downloads"
case "$url" in https://github.com/shin1ohno/ai-memory/releases/download/bin-*/*) ;; *) exit 3 ;; esac
rest=${url#https://github.com/shin1ohno/ai-memory/releases/download/bin-}
[ -f "$FIXTURE_RELEASE/${rest%%/*}/${rest#*/}" ] || exit 22
cp "$FIXTURE_RELEASE/${rest%%/*}/${rest#*/}" "$out"
'''

# Units are files under $FIXTURE_UNITS/<unit>: "active <pid> <exe>" or "inactive".
SYSTEMCTL = r'''#!/bin/bash
f=$FIXTURE_UNITS/${@: -1}
case "$1" in
is-active) [ "$(cut -d' ' -f1 "$f" 2>/dev/null)" = active ] ;;
show) cut -d' ' -f2 "$f" ;;
restart)
  read -r _ pid exe < "$f"
  kill -9 "$pid" 2>/dev/null
  echo "$*" >> "$FIXTURE_UNITS/restarts"
  setsid "$exe" -c 'kill -STOP $$' >/dev/null 2>&1 < /dev/null &
  echo "active $! $exe" > "$f" ;;
*) exit 9 ;;
esac
'''


def script_tests(work):
    base = work / "opt"; base.mkdir()
    tools = work / "tools"; tools.mkdir()
    release = work / "release"; release.mkdir()
    units = work / "units"; units.mkdir()
    for name, body in (("curl", CURL), ("systemctl", SYSTEMCTL)):
        (tools / name).write_text(body)
        (tools / name).chmod(0o755)
    env = dict(os.environ, PATH="%s:%s" % (tools, os.environ["PATH"]),
               FIXTURE_RELEASE=str(release), FIXTURE_UNITS=str(units))
    srcs = [c * 40 for c in "123"]

    def publish(src, content=None):
        d = release / src; d.mkdir(exist_ok=True)
        if content is None:
            shutil.copy(BASH, d / NAME)
        else:
            (d / NAME).write_bytes(content); (d / NAME).chmod(0o755)
        return sha256(d / NAME)

    def run(*args, expect=0, label=""):
        p = subprocess.run(["/bin/bash", str(SCRIPT)] + [str(a) for a in args], env=env, capture_output=True, text=True)
        ok = p.returncode == expect
        check(ok, "%s (exit %d)" % (label, p.returncode))
        if not ok:
            print("      " + (p.stdout + p.stderr).strip().replace("\n", "\n      "))
        return p

    bin_dir = base / "bin"
    sums = {s: publish(s) for s in srcs}

    def asset(src, sha=None):
        return "%s=%s" % (NAME, sha or sums[src])

    def state():
        cur = os.readlink(bin_dir / "current") if (bin_dir / "current").is_symlink() else None
        return cur, sorted(p.name for p in bin_dir.iterdir()) if bin_dir.exists() else []

    # first stage and activate
    run("stage", srcs[0], base, asset(srcs[0]), label="stage downloads, verifies and renames")
    d0 = bin_dir / srcs[0]
    check((d0 / NAME).is_file() and oct((d0 / NAME).stat().st_mode & 0o777) == "0o755"
          and sha256(d0 / NAME) == sums[srcs[0]], "staged binary is a 755 file with the pinned sha256")
    check(not list(bin_dir.glob(".staging-*")), "no staging directory is left behind")
    run("check-staged", srcs[0], base, asset(srcs[0]), label="check-staged passes on the staged directory")
    downloads = (release / "downloads").read_text().count("\n")
    run("stage", srcs[0], base, asset(srcs[0]), label="a second stage is a no-op")
    check((release / "downloads").read_text().count("\n") == downloads, "a staged pin is not downloaded again")
    run("check-active", srcs[0], base, expect=1, label="check-active fails before activation")
    run("activate", srcs[0], base, label="activate points current at the pin")
    run("check-active", srcs[0], base, label="check-active passes after activation")
    check(state()[0] == srcs[0], "current -> %s" % srcs[0][:7])

    # a running unit on the first version
    exe0 = str(d0 / NAME)
    proc = subprocess.Popen([exe0] + PARK, start_new_session=True)
    (units / UNIT).write_text("active %d %s\n" % (proc.pid, str(bin_dir / "current" / NAME)))
    pair = "%s=%s" % (UNIT, NAME)
    run("stale", base, pair, expect=1, label="a unit running current is not stale")
    before = state()

    # (a) wrong sha256: nothing changes
    run("stage", srcs[1], base, asset(srcs[1], "f" * 64), expect=1, label="(a) a wrong sha256 fails the stage")
    check(state() == before and not (bin_dir / srcs[1]).exists(), "(a) current and the binary directories are unchanged")
    run("stale", base, pair, expect=1, label="(a) the running unit is untouched")

    # (b) a tag that does not exist, then the right pin converges with no manual step
    run("stage", "9" * 40, base, asset(srcs[1]), expect=1, label="(b) a missing release fails the stage")
    check(state()[0] == srcs[0] and not (bin_dir / ("9" * 40)).exists(), "(b) current is unchanged")
    run("stage", srcs[1], base, asset(srcs[1]), label="(b) the right pin stages afterwards without cleanup")

    # a binary that cannot execute (for example SIGILL on a CPU without AVX2)
    sigill = publish(srcs[2], b"#!/bin/sh\nkill -ILL $$\n")
    run("stage", srcs[2], base, asset(srcs[2], sigill), expect=1, label="a binary whose --version dies is not staged")
    check(not (bin_dir / srcs[2]).exists(), "the failed binary has no directory")
    sums[srcs[2]] = publish(srcs[2])

    # (c) activate, then the converge stops before the restart
    run("activate", srcs[1], base, label="(c) activate the second version")
    p = run("stale", base, pair, label="(c) the unit still running the old binary is stale")
    check(srcs[0] in p.stdout, "(c) stale names the old executable")
    run("restart-stale", base, pair, label="(c) the next converge restarts it")
    pid = int((units / UNIT).read_text().split()[1])
    time.sleep(0.2)
    exe = os.readlink("/proc/%d/exe" % pid)
    check(exe == os.path.realpath(bin_dir / "current" / NAME) and srcs[1] in exe,
          "(c) /proc/<pid>/exe is the file under current")
    run("stale", base, pair, expect=1, label="(c) nothing is stale afterwards")
    restarts = (units / "restarts").read_text().count("\n")
    run("restart-stale", base, pair, label="restart-stale with nothing stale")
    check((units / "restarts").read_text().count("\n") == restarts, "nothing stale means no restart")
    (units / "other.service").write_text("inactive\n")
    run("stale", base, "other.service=%s" % NAME, expect=1, label="an inactive unit is never restarted")

    # a tampered staged binary is replaced on the next stage
    # Replaced, not rewritten: the unit is running this file.
    (bin_dir / srcs[1] / NAME).unlink()
    (bin_dir / srcs[1] / NAME).write_bytes(b"tampered"); (bin_dir / srcs[1] / NAME).chmod(0o755)
    run("check-staged", srcs[1], base, asset(srcs[1]), expect=1, label="check-staged detects a tampered binary")
    run("stage", srcs[1], base, asset(srcs[1]), label="stage replaces the tampered directory")
    check(sha256(bin_dir / srcs[1] / NAME) == sums[srcs[1]] and state()[0] == srcs[1], "the replacement keeps current valid")
    (bin_dir / srcs[1] / "extra").write_text("x")
    run("check-staged", srcs[1], base, asset(srcs[1]), expect=1, label="check-staged refuses an extra file")
    (bin_dir / srcs[1] / "extra").unlink()

    # retention: 3 newest directories, current always kept
    run("stage", srcs[2], base, asset(srcs[2]), label="stage a third version")
    old = "4" * 40
    (bin_dir / old).mkdir(); os.utime(bin_dir / old, (1, 1))
    (bin_dir / ".staging-x").mkdir()
    run("activate", srcs[2], base, label="activate the third version")
    kept = [n for n in state()[1] if len(n) == 40]
    check(sorted(kept) == sorted(srcs) and old not in kept and ".staging-x" not in state()[1],
          "activate keeps the 3 newest directories and removes leftovers: %s" % [k[:4] for k in kept])

    # argument validation
    run("stage", srcs[0], "relative", asset(srcs[0]), expect=1, label="a relative base is refused")
    run("stage", srcs[0], base, "noop=%s" % sums[srcs[0]], expect=1, label="a name outside ai-memory-* is refused")
    run("stage", srcs[0], base, asset(srcs[0]), asset(srcs[0]), expect=1, label="a duplicate asset is refused")
    run("stage", "x" * 40, base, asset(srcs[0]), expect=1, label="a non-hex source_sha is refused")
    link = work / "link"; link.symlink_to(base)
    run("stage", srcs[0], link, asset(srcs[0]), expect=1, label="a symlinked base is refused")
    check("--proto" in SCRIPT.read_text() and "=https" in SCRIPT.read_text(), "downloads are restricted to https")

    for f in units.iterdir():
        if f.name.endswith(".service") and f.read_text().startswith("active"):
            try:
                os.kill(int(f.read_text().split()[1]), signal.SIGKILL)
            except ProcessLookupError:
                pass
    proc.wait(timeout=5)


def main():
    with tempfile.TemporaryDirectory(prefix="ai-memory-bin-") as work:
        work = Path(work)
        recipe_tests(work)
        script_tests(work)
    print("FAIL: %d checks failed" % failures if failures else "OK: ai-memory binary track")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
