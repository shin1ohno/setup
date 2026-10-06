import contextlib
import hashlib
import io
import json
import os
import tarfile
import unittest

import support
from support import SID, FakeServer, HomeCase, user

from ccs import resume, util

ORIG_PROJ = "-old-host-work-demo"


def make_tar(members):
    """members: list of (name, bytes) or (name, TarInfo-mutator)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, data, kind in members:
            ti = tarfile.TarInfo(name)
            if kind == "sym":
                ti.type = tarfile.SYMTYPE
                ti.linkname = "/etc/passwd"
                tf.addfile(ti)
            elif kind == "dir":
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


class Restore(HomeCase):
    def setUp(self):
        super().setUp()
        self.cwd = os.path.join(self.tmp, "work", "demo")
        os.makedirs(self.cwd)
        self.archive = (json.dumps(user("hi", cwd="/old/work/demo")) + "\n" + json.dumps(
            {"type": "user", "toolUseResult": {"path": "/home/old/.claude/projects/%s/%s/tool-results/toolu_1.txt"
                                                        % (ORIG_PROJ, SID)}}) + "\n").encode()
        self.sha = hashlib.sha256(self.archive).hexdigest()
        self.tar = make_tar([("toolu_1.txt", b"masked output", "file")])
        self.meta = {"session_key": "sk_r", "session_id": SID, "host": "mini", "project_dir": ORIG_PROJ,
                     "resume_cwd": "/does/not/exist/here", "jsonl_path": "/x/y.jsonl", "jsonl_exists": True,
                     "archived": True, "archive_complete": True}
        self.srv = FakeServer(self.handler)
        self.write_config(self.srv.base + "/memory/sessions/v1", host="pro-dev")
        self.execs = []

    def tearDown(self):
        self.srv.close()
        super().tearDown()

    def handler(self, req):
        if req["path"].endswith("/preview"):
            return 200, {"session": self.meta, "snippets": []}, {}
        if req["path"].endswith("/archive"):
            return 200, self.archive, {"X-Archive-Sha256": self.sha, "Content-Type": "application/x-ndjson"}
        if req["path"].endswith("/archive/tool-results"):
            return 200, self.tar, {"Content-Type": "application/x-tar"}
        return 404, {}, {}

    def go(self, **kw):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = resume.resume("sk_r", to_dir=self.cwd, execvp=lambda f, a: self.execs.append(a),
                                 chdir=lambda d: self.execs.append(("chdir", d)), out=io.StringIO(), **kw)
        return code, err.getvalue()

    def target(self):
        return os.path.join(self.projects, util.encode_cwd(self.cwd), SID + ".jsonl")

    def test_restore_then_exec(self):
        code, err = self.go()
        self.assertEqual(code, 0, err)
        self.assertIn(resume.RESTORED_NOTE, err)
        self.assertEqual(self.execs, [("chdir", self.cwd), ["claude", "--resume", SID]])
        body = support.read(self.target())
        new_tr = os.path.join(self.projects, util.encode_cwd(self.cwd), SID, "tool-results") + "/"
        self.assertIn(new_tr + "toolu_1.txt", body)
        self.assertNotIn(ORIG_PROJ, body)
        self.assertEqual(support.read(new_tr + "toolu_1.txt", "rb"), b"masked output")
        self.assertFalse(os.path.exists(self.target() + ".tmp"))

    def test_project_dir_is_local_encoding_not_server_value(self):
        self.meta["project_dir"] = "../../../evil"
        code, _ = self.go()
        self.assertEqual(code, 0)
        self.assertTrue(os.path.exists(self.target()))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "evil")))

    def test_bad_session_id_refused(self):
        for bad in ("../../etc/passwd", "ABCDEF00-0000-0000-0000-000000000000", SID + "x", ""):
            self.meta["session_id"] = bad
            code, err = self.go()
            self.assertEqual(code, util.EXIT_RESUME, bad)
            self.assertIn("refusing session_id", err)
        self.assertEqual(self.execs, [])

    def test_sha_mismatch_restores_nothing(self):
        self.sha = "0" * 64
        code, err = self.go()
        self.assertEqual(code, util.EXIT_RESUME)
        self.assertIn("sha256 mismatch", err)
        self.assertFalse(os.path.exists(self.target()))
        self.assertFalse(os.path.exists(self.target() + ".tmp"))

    def test_traversal_member_names_refused(self):
        for members in ([("../escape.txt", b"x", "file")], [("/abs.txt", b"x", "file")],
                        [("sub/inner.txt", b"x", "file")], [("link.txt", b"", "sym")], [("d", b"", "dir")],
                        [(".hidden", b"x", "file")]):
            self.tar = make_tar(members)
            code, err = self.go()
            self.assertEqual(code, util.EXIT_RESUME, members)
            self.assertIn("unsafe member", err)
            self.assertFalse(os.path.exists(self.target()))
        self.assertFalse(os.path.exists(os.path.join(self.projects, "escape.txt")))

    def test_existing_different_file_needs_force(self):
        os.makedirs(os.path.dirname(self.target()))
        with open(self.target(), "w") as fh:
            fh.write("{}\n")
        code, err = self.go()
        self.assertEqual(code, util.EXIT_RESUME)
        self.assertIn("--force", err)
        self.assertEqual(support.read(self.target()), "{}\n")
        code, _ = self.go(force=True)
        self.assertEqual(code, 0)
        self.assertNotEqual(support.read(self.target()), "{}\n")

    def test_identical_existing_file_is_fine(self):
        self.assertEqual(self.go()[0], 0)
        self.assertEqual(self.go()[0], 0)

    def test_not_archived_is_view_only(self):
        self.meta["archived"] = False
        code, err = self.go()
        self.assertEqual(code, util.EXIT_RESUME)
        self.assertIn("view-only", err)

    def test_incomplete_archive_is_view_only(self):
        self.meta["archive_complete"] = False
        code, err = self.go()
        self.assertEqual(code, util.EXIT_RESUME)
        self.assertIn("archive incomplete", err)

    def test_local_session_exec_and_missing_cwd(self):
        p = self.transcript([user("x", cwd=self.cwd)], cwd=self.cwd)
        self.meta.update(host="pro-dev", jsonl_path=p, resume_cwd=self.cwd)
        self.assertEqual(self.go(fork=True)[0], 0)
        self.assertEqual(self.execs[-1], ["claude", "--resume", SID, "--fork-session"])
        self.meta["resume_cwd"] = "/gone/dir"
        code, err = self.go()
        self.assertEqual(code, util.EXIT_RESUME)
        self.assertIn("does not exist", err)

    def test_print_command(self):
        p = self.transcript([user("x", cwd=self.cwd)], cwd=self.cwd)
        self.meta.update(host="pro-dev", jsonl_path=p, resume_cwd=self.cwd)
        out = io.StringIO()
        with contextlib.redirect_stderr(io.StringIO()):
            code = resume.resume("sk_r", do_print=True, execvp=lambda *a: self.fail("exec"), out=out)
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue().strip(), "cd %s && claude --resume %s" % (self.cwd, SID))

    def test_rewrite_only_matches_this_session(self):
        text = '"/h/.claude/projects/%s/%s/tool-results/a" "/h/.claude/projects/%s/other/tool-results/b"' % (
            ORIG_PROJ, SID, ORIG_PROJ)
        out = resume.rewrite_tool_result_paths(text, ORIG_PROJ, SID, "/new/dir")
        self.assertIn('"/new/dir/a"', out)
        self.assertIn("/other/tool-results/b", out)


class RestoreWithoutDataFilter(Restore):
    """Same cases on a Python whose tarfile predates the `data` filter (manual validation path)."""

    def setUp(self):
        super().setUp()
        self._saved = getattr(tarfile, "data_filter", None)
        if self._saved is not None:
            del tarfile.data_filter

    def tearDown(self):
        if self._saved is not None:
            tarfile.data_filter = self._saved
        super().tearDown()


if __name__ == "__main__":
    unittest.main()
