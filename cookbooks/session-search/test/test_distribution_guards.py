"""Exercise shared shell guards with long output and failed producers."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[3]


class DistributionGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ccs-guards-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.commands = self.work / "commands"
        self.commands.mkdir()
        self.pin = "1" * 40
        self.env = dict(os.environ, PATH=str(self.commands) + os.pathsep + os.environ["PATH"])

    def command(self, name, script):
        path = self.commands / name
        path.write_text(script)
        path.chmod(0o755)

    def shell(self, script, *args, extra=None, pipefail=True):
        shell = ["/bin/bash", "-eu"]
        if pipefail:
            shell += ["-o", "pipefail"]
        return subprocess.run(
            [*shell, "-c", script, "guard-test", *map(str, args)],
            env=dict(self.env, **(extra or {})), text=True, capture_output=True)

    def artifact(self, **extra):
        # The real checksum and chmod run; only download and gh are fixtures.
        source = self.work / "download"
        source.write_text("fixture artifact\n")
        self.command("curl", '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done\ncp "$FIXTURE_DOWNLOAD" "$2"\n')
        self.command("gh", "#!" + sys.executable + '''
import os, signal, sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
if sys.argv[1:] == ["attestation", "verify", "--help"]:
    mode = os.environ.get("HELP_MODE", "long")
    if mode != "missing":
        os.write(1, b"--source-digest\\n")
    # A matching first line followed by much more than a pipe buffer makes
    # an early-closing consumer fail reliably, regardless of scheduling.
    for _ in range(32):
        os.write(1, b"help padding " * 1024 + b"\\n")
    sys.exit(19 if mode == "failed" else 0)
with open(os.environ["FIXTURE_VERIFIED"], "w") as marker:
    marker.write("verified\\n")
print("fixture attestation verified")
''')
        return self.shell('''
source "$1/bin/lib/session-search-era.sh"
source "$1/bin/lib/session-search-artifact.sh"
ss_manifest_pin=$2
ss_sums="$3 x86_64-unknown-linux-gnu"
if ss_artifact "$2" x86_64-unknown-linux-gnu "$4"; then exit 0; else exit 1; fi
''', REPO, self.pin, hashlib.sha256(source.read_bytes()).hexdigest(), self.work / "ccs",
            extra=dict(FIXTURE_DOWNLOAD=str(source), FIXTURE_VERIFIED=str(self.work / "verified"), **extra))

    def test_long_help_repeated(self):
        for attempt in range(20):
            result = self.artifact()
            self.assertEqual(result.returncode, 0, (attempt, result.stdout, result.stderr))
            self.assertTrue((self.work / "ccs").stat().st_mode & 0o111)
            self.assertEqual((self.work / "verified").read_text(), "verified\n")
        print("PASS artifact: 20/20 long-help runs without SIGPIPE", flush=True)

    def test_failed_help_is_not_a_capability(self):
        result = self.artifact(HELP_MODE="failed")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("gh attestation help failed", result.stderr)
        self.assertFalse((self.work / "verified").exists())

    def test_missing_capability(self):
        result = self.artifact(HELP_MODE="missing")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("upgrade gh", result.stderr)
        self.assertFalse((self.work / "verified").exists())

    def era(self, history, status, pipefail):
        self.command("git", '''#!/bin/sh
case "$3" in
  merge-base) exit 0 ;;
  log) printf '%s' "$FIXTURE_HISTORY"; exit "$FIXTURE_LOG_STATUS" ;;
  *) exit 91 ;;
esac
''')
        manifest = self.work / "manifest"
        manifest.write_text("pin " + self.pin + "\n")
        # Call in a conditional, as callers do: errexit alone is insufficient.
        return self.shell('''
source "$1/bin/lib/session-search-era.sh"
if ss_era "$2" "$3" "$4"; then exit 0; else exit 1; fi
''', REPO, self.work, self.pin, manifest,
            extra=dict(FIXTURE_HISTORY=history, FIXTURE_LOG_STATUS=str(status)), pipefail=pipefail)

    def test_history_baselines(self):
        for pipefail in (False, True):
            for history, era in (("", "python"), (self.pin + "\n" + "2" * 40 + "\n", "rust")):
                with self.subTest(pipefail=pipefail, era=era):
                    result = self.era(history, 0, pipefail)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("ERA " + era, result.stdout)
                    if history:
                        self.assertIn("boundary=" + self.pin + "\n", result.stdout)

    def test_failed_history_never_classifies(self):
        for pipefail in (False, True):
            for history in ("", self.pin + "\n"):
                with self.subTest(pipefail=pipefail, partial=bool(history)):
                    result = self.era(history, 73, pipefail)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("cannot read Rust boundary history", result.stderr)
                    self.assertNotIn("ERA ", result.stdout)
                    print("PASS era: git log exit 73 rejected, pipefail=%s partial=%s" %
                          (pipefail, bool(history)), flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
