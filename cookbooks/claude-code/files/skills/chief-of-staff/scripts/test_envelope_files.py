"""Bounded special-file rejection and descriptor-race regressions, private ledgers only."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_envelopes as fixtures

SPEC = importlib.util.spec_from_file_location("tasks_files", Path(__file__).with_name("tasks.py"))
tasks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tasks)


class EnvelopeFileTest(unittest.TestCase):
    # Share only the existing private-ledger fixture and CLI helpers.
    setUp = fixtures.EnvelopeTest.setUp
    call = fixtures.EnvelopeTest.call
    mutate = fixtures.EnvelopeTest.mutate
    start = fixtures.EnvelopeTest.start
    envelope = fixtures.EnvelopeTest.envelope

    def bounded_receive(self, path, success=False):
        child = subprocess.Popen([sys.executable, str(Path(tasks.__file__)), "receive", self.task,
            "--owner", self.owner, "--file", str(path)], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = child.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            self.fail("receive blocked on an envelope file")
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()
        self.assertEqual(child.returncode, 0 if success else 1, stderr)
        # Each call takes the same global flock; a leaked lock fails with timeout.
        state = self.call("show", self.task)["task"]["state"]
        self.assertEqual(state, "reviewing" if success else "running")
        return stdout, stderr

    def test_regular_and_contained_symlink_positive_controls(self):
        self.start()
        regular = self.envelope()
        self.bounded_receive(regular, success=True)
        link = self.directory / "contained-link"
        link.symlink_to(regular)
        self.bounded_receive(link, success=True)

    def test_fifo_socket_directory_oversized_and_utf8_release_lock(self):
        self.start()
        fifo = self.directory / "envelope.fifo"
        os.mkfifo(fifo)
        directory = self.directory / "envelope-dir"
        directory.mkdir()
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        socket_path = self.root / "socket"
        sock.bind(str(socket_path))
        self.bounded_receive(socket_path)
        for path, data in [(self.directory / "large", b"x" * 16385),
                           (self.directory / "invalid-utf8", b"\xff")]:
            path.write_bytes(data)
        for path in [fifo, directory, self.directory / "large", self.directory / "invalid-utf8"]:
            self.bounded_receive(path)
        self.bounded_receive(self.envelope(), success=True)


class DescriptorRaceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cos-files-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.file = self.root / "envelope.json"
        self.file.write_bytes(b"{}")

    def test_nonregular_device_and_socket_are_not_opened(self):
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        with tempfile.TemporaryDirectory(prefix="cos-s-", dir="/tmp") as short:
            path = Path(short).resolve() / "socket"
            sock.bind(str(path))
            with self.assertRaises(ValueError):
                tasks.envelope_bytes(path, [path.parent])
        with self.assertRaises(ValueError):
            tasks.envelope_bytes(Path("/dev/null"), [Path("/dev")])

    def test_final_fifo_replacement_does_not_block_and_closes_descriptors(self):
        # Run the deterministic swap in a reaped child so a regression cannot hang tests.
        code = '''import importlib.util, os, sys
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location("tasks",sys.argv[1]); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
p=Path(sys.argv[2]); real=os.open; opened=[]; closed=[]; close=os.close
def swap(name,flags,*args,**kwargs):
 if name==p.name:
  p.unlink(); os.mkfifo(p)
 fd=real(name,flags,*args,**kwargs);opened.append(fd);return fd
def record(fd):
 closed.append(fd);close(fd)
with patch.object(m.os,"open",side_effect=swap),patch.object(m.os,"close",side_effect=record):
 try:m.envelope_bytes(p,[p.parent])
 except ValueError:pass
 else:raise AssertionError("FIFO accepted")
assert set(opened)==set(closed),(opened,closed)
'''
        child = subprocess.Popen([sys.executable, "-c", code, str(Path(tasks.__file__)), str(self.file)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            _, stderr = child.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            self.fail("FIFO replacement blocked read")
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()
        self.assertEqual(child.returncode, 0, stderr)

    def test_open_descriptor_keeps_original_file_after_name_replacement(self):
        outside = self.root / "replacement.json"
        outside.write_bytes(b"replacement content")
        real_read = os.read
        def replace_then_read(descriptor, limit):
            self.file.unlink()
            self.file.symlink_to(outside)
            return real_read(descriptor, limit)
        with patch.object(tasks.os, "read", side_effect=replace_then_read):
            self.assertEqual(tasks.envelope_bytes(self.file, [self.root]), b"{}")

    def test_symlink_and_parent_replacements_cannot_escape(self):
        outside = self.root / "outside.json"
        outside.write_bytes(b"outside")
        real_open = os.open
        def swap(name, flags, *args, **kwargs):
            if name == self.file.name:
                self.file.unlink()
                self.file.symlink_to(outside)
            return real_open(name, flags, *args, **kwargs)
        with patch.object(tasks.os, "open", side_effect=swap), self.assertRaises(OSError):
            tasks.envelope_bytes(self.file, [self.root])
        self.file.unlink()
        parent = self.root / "parent"
        parent.mkdir()
        file = parent / "envelope.json"
        file.write_bytes(b"{}")
        def swap_parent(name, flags, *args, **kwargs):
            if name == "parent":
                parent.rename(self.root / "old-parent")
                parent.symlink_to(self.root, target_is_directory=True)
            return real_open(name, flags, *args, **kwargs)
        with patch.object(tasks.os, "open", side_effect=swap_parent), self.assertRaises(OSError):
            tasks.envelope_bytes(file, [self.root])


if __name__ == "__main__":
    unittest.main()
