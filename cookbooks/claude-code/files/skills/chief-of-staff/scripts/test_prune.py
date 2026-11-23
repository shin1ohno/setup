"""Exercise prune.py against real git checkouts in a throwaway state directory."""

from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prune.py")
GIT_ENV = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
               GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")


def git(cwd, *args):
    return subprocess.run(["git", "-c", "init.defaultBranch=main", *args], cwd=cwd,
                           env=GIT_ENV, check=True, capture_output=True, text=True).stdout


class PruneTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.root = self.tmp / "state"
        self.root.mkdir()
        self.origin = self.tmp / "origin.git"
        git(self.tmp, "init", "--bare", "-q", str(self.origin))
        seed = self.tmp / "seed"
        git(self.tmp, "clone", "-q", str(self.origin), str(seed))
        (seed / "a.txt").write_text("one\n")
        (seed / ".gitignore").write_text("build/\n")
        git(seed, "add", ".")
        git(seed, "commit", "-qm", "seed")
        git(seed, "push", "-q", "origin", "HEAD:main")
        self.env = dict(GIT_ENV, COS_STATE_DIR=str(self.root))

    def task(self, task_id, state="accepted", ended_days_ago=1):
        task_dir = self.root / task_id
        task_dir.mkdir()
        at = (datetime.now(timezone.utc) - timedelta(days=ended_days_ago or 0)).isoformat()
        history = [{"at": at, "state": "running"}]
        if state in ("accepted", "cancelled") and ended_days_ago is not None:
            history.append({"at": at, "state": state})
        (task_dir / "task.json").write_text(json.dumps({"id": task_id, "state": state,
                                                        "history": history}))
        (task_dir / "report-1.md").write_text("evidence\n")
        return task_dir

    def clone(self, task_dir, name="repo"):
        path = task_dir / "attempt-1" / name
        path.parent.mkdir(exist_ok=True)
        git(self.tmp, "clone", "-q", str(self.origin), str(path))
        return path

    def run_prune(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stderr + result.stdout)
        return json.loads(result.stdout)

    def test_clean_pushed_clone_is_removed_and_records_stay(self):
        task_dir = self.task("a" * 16)
        repo = self.clone(task_dir)
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["deleted"], 1)
        self.assertFalse(repo.exists())
        self.assertTrue((task_dir / "task.json").exists())
        self.assertTrue((task_dir / "report-1.md").exists())
        self.assertEqual(len(list(task_dir.glob("pruned-*.json"))), 1)

    def test_dry_run_changes_nothing(self):
        task_dir = self.task("a" * 16)
        repo = self.clone(task_dir)
        out = self.run_prune("--terminal")
        self.assertEqual((out["apply"], out["repos"], out["deleted"]), (False, 1, 0))
        self.assertTrue(repo.exists())
        self.assertEqual(list(task_dir.glob("pruned-*.json")), [])

    def test_non_terminal_task_is_untouched(self):
        task_dir = self.task("a" * 16, state="running")
        repo = self.clone(task_dir)
        out = self.run_prune("--terminal", "--apply")
        self.assertEqual(out["skipped"], {"not-terminal": 1})
        self.assertTrue(repo.exists())

    def unsaved_clone(self, task_dir):
        repo = self.clone(task_dir)
        (repo / "a.txt").write_text("one\nlocal commit\n")
        git(repo, "commit", "-qam", "unpushed work")
        (repo / "a.txt").write_text("one\nlocal commit\nuncommitted edit\n")
        (repo / "new.txt").write_text("untracked\n")
        return repo

    def test_unsaved_kinds_stay_while_recent(self):
        task_dir = self.task("a" * 16, ended_days_ago=6)
        kinds = {}
        for name in ("dirty", "untracked", "unpushed", "stash"):
            kinds[name] = self.clone(task_dir, name)
        (kinds["dirty"] / "a.txt").write_text("changed\n")
        (kinds["untracked"] / "b.txt").write_text("new\n")
        (kinds["unpushed"] / "a.txt").write_text("committed\n")
        git(kinds["unpushed"], "commit", "-qam", "local")
        (kinds["stash"] / "a.txt").write_text("stashed\n")
        git(kinds["stash"], "stash", "-q")
        unborn = task_dir / "attempt-1" / "unborn"
        git(self.tmp, "init", "-q", str(unborn))
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["kept"], {"unsaved-recent": 5})
        self.assertEqual(out["deleted"], 0)
        for path in [*kinds.values(), unborn]:
            self.assertTrue(path.exists(), path)

    def test_unknown_end_time_never_expires(self):
        task_dir = self.task("a" * 16, ended_days_ago=None)
        repo = self.unsaved_clone(task_dir)
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["kept"], {"unsaved-age-unknown": 1})
        self.assertTrue(repo.exists())

    def test_expired_unsaved_work_is_saved_restorable_then_removed(self):
        task_dir = self.task("a" * 16, ended_days_ago=8)
        repo = self.unsaved_clone(task_dir)
        (repo / "a.txt").write_text("one\nlocal commit\nuncommitted edit\n")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual((out["deleted"], out["errors"]), (1, 0), out)
        self.assertFalse(repo.exists())
        saved = task_dir / "pruned" / "attempt-1" / "repo"
        manifest = json.loads((saved / "manifest.json").read_text())
        self.assertEqual(sorted(manifest["files"]),
                         ["tracked.diff", "unpushed.bundle", "untracked.txt"])
        self.assertEqual((saved / "untracked.txt").read_text(), "new.txt\n")
        fresh = self.tmp / "fresh"
        git(self.tmp, "clone", "-q", str(self.origin), str(fresh))
        git(fresh, "fetch", "-q", str(saved / "unpushed.bundle"), "main:restored")
        git(fresh, "checkout", "-q", "restored")
        self.assertEqual(git(fresh, "log", "-1", "--format=%s").strip(), "unpushed work")
        git(fresh, "apply", str(saved / "tracked.diff"))
        self.assertEqual((fresh / "a.txt").read_text(), "one\nlocal commit\nuncommitted edit\n")

    def test_expired_stash_is_bundled(self):
        task_dir = self.task("a" * 16, ended_days_ago=8)
        repo = self.clone(task_dir)
        (repo / "a.txt").write_text("stashed\n")
        git(repo, "stash", "-q")
        self.run_prune("a" * 16, "--apply")
        self.assertFalse(repo.exists())
        bundle = task_dir / "pruned" / "attempt-1" / "repo" / "unpushed.bundle"
        heads = git(self.tmp, "bundle", "list-heads", str(bundle))
        self.assertIn("refs/stash", heads)

    def test_failed_save_keeps_the_checkout(self):
        task_dir = self.task("a" * 16, ended_days_ago=8)
        repo = self.unsaved_clone(task_dir)
        (task_dir / "pruned").write_text("not a directory\n")
        out = self.run_prune("a" * 16, "--apply", ok=False)
        self.assertEqual(out["kept"], {"save-failed": 1})
        self.assertTrue(repo.exists())
        self.assertEqual(git(repo, "log", "-1", "--format=%s").strip(), "unpushed work")

    def test_linked_worktrees_are_removed_and_unregistered(self):
        task_dir = self.task("a" * 16)
        main = self.clone(task_dir)
        inner = task_dir / "attempt-1" / "wt"
        git(main, "worktree", "add", "-q", "--detach", str(inner))
        external_main = self.tmp / "outside-main"
        git(self.tmp, "clone", "-q", str(self.origin), str(external_main))
        outer = task_dir / "attempt-1" / "wt-external"
        git(external_main, "worktree", "add", "-q", "--detach", str(outer))
        (outer / "build").mkdir()
        (outer / "build" / "out.o").write_text("ignored output\n")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual((out["deleted"], out["errors"]), (3, 0), out)
        self.assertFalse(main.exists() or inner.exists() or outer.exists())
        self.assertNotIn(str(outer), git(external_main, "worktree", "list"))

    def test_repository_with_a_worktree_outside_the_task_stays(self):
        task_dir = self.task("a" * 16)
        main = self.clone(task_dir)
        git(main, "worktree", "add", "-q", "--detach", str(self.tmp / "elsewhere"))
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["kept"], {"external-worktree": 1})
        self.assertTrue(main.exists())

    def test_tagged_caches_go_and_name_alone_is_not_a_cache(self):
        task_dir = self.task("a" * 16)
        target = task_dir / "attempt-1" / "target-mut"
        target.mkdir(parents=True)
        (target / "CACHEDIR.TAG").write_text("Signature: 8a477f597d28d172789f06886806bc55\n")
        modules = task_dir / "web" / "node_modules"
        modules.mkdir(parents=True)
        evidence = task_dir / "integration-invalid-cache"
        evidence.mkdir()
        (evidence / "result.json").write_text("{}\n")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["deleted"], 2)
        self.assertFalse(target.exists() or modules.exists())
        self.assertTrue((evidence / "result.json").exists())

    def test_symlinks_are_not_followed(self):
        task_dir = self.task("a" * 16)
        outside = self.tmp / "outside"
        outside.mkdir()
        (outside / "CACHEDIR.TAG").write_text("Signature: 8a477f597d28d172789f06886806bc55\n")
        (outside / "keep.txt").write_text("keep\n")
        (task_dir / "node_modules").symlink_to(outside)
        (task_dir / "cache-link").symlink_to(outside)
        self.run_prune("a" * 16, "--apply")
        self.assertTrue((outside / "keep.txt").exists())
        self.assertTrue((task_dir / "node_modules").is_symlink())
        self.assertTrue((task_dir / "cache-link").is_symlink())

    def test_alternates_source_stays_until_its_borrower_is_gone(self):
        task_dir = self.task("a" * 16)
        source = self.clone(task_dir, "checkout")
        borrower = task_dir / "attempt-1" / "mutation-clone"
        git(self.tmp, "clone", "-q", "--shared", str(source), str(borrower))
        (borrower / "probe.rs").write_text("untracked probe\n")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["kept"], {"alternates-source": 1, "unsaved-recent": 1})
        self.assertTrue(source.exists())
        git(borrower, "fsck", "--connectivity-only")

    def test_alternates_source_goes_once_the_borrower_is_removed(self):
        task_dir = self.task("a" * 16)
        source = self.clone(task_dir, "checkout")
        borrower = task_dir / "attempt-1" / "shared"
        git(self.tmp, "clone", "-q", "--shared", str(source), str(borrower))
        first = self.run_prune("a" * 16, "--apply")
        self.assertEqual((first["deleted"], first["kept"]), (1, {"alternates-source": 1}))
        second = self.run_prune("a" * 16, "--apply")
        self.assertEqual(second["deleted"], 1)
        self.assertFalse(source.exists() or borrower.exists())

    def test_submodule_stash_keeps_the_parent(self):
        task_dir = self.task("a" * 16)
        parent = self.clone(task_dir, "parent")
        git(parent, "-c", "protocol.file.allow=always", "submodule", "add", "-q",
            str(self.origin), "sub")
        git(parent, "commit", "-qm", "add submodule")
        git(parent, "push", "-q", "origin", "HEAD:main")
        sub = parent / "sub"
        (sub / "a.txt").write_text("stashed in the submodule\n")
        git(sub, "stash", "-q")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["kept"], {"unsaved-recent": 1, "shares-kept-repo": 1})
        self.assertIn("stash@{0}", git(sub, "stash", "list"))

    def test_refused_worktree_removal_keeps_its_repository(self):
        task_dir = self.task("a" * 16)
        main = self.clone(task_dir)
        linked = task_dir / "attempt-1" / "wt"
        git(main, "worktree", "add", "-q", "--detach", str(linked))
        git(main, "worktree", "lock", str(linked))
        out = self.run_prune("a" * 16, "--apply", ok=False)
        self.assertEqual(out["kept"], {"remove-failed": 2})
        self.assertTrue(main.exists() and linked.exists())
        self.assertIn(str(linked), git(main, "worktree", "list"))

    def test_unsigned_cachedir_tag_is_not_a_cache(self):
        task_dir = self.task("a" * 16)
        evidence = task_dir / "evidence"
        evidence.mkdir()
        (evidence / "CACHEDIR.TAG").write_text("not the signature\n")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual(out["deleted"], 0)
        self.assertTrue(evidence.exists())

    def test_attempt_directory_is_never_a_cache(self):
        task_dir = self.task("a" * 16)
        attempt = task_dir / "attempt-1"
        attempt.mkdir()
        (attempt / "CACHEDIR.TAG").write_text("Signature: 8a477f597d28d172789f06886806bc55\n")
        (attempt / "brief.md").write_text("brief\n")
        self.run_prune("a" * 16, "--apply")
        self.assertTrue((attempt / "brief.md").exists())

    def test_task_in_use_is_skipped(self):
        task_dir = self.task("a" * 16)
        repo = self.clone(task_dir)
        holder = subprocess.Popen(["sleep", "30"], cwd=repo)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        out = self.run_prune("--terminal", "--apply")
        self.assertEqual(out["skipped"], {"busy": 1})
        self.assertTrue(repo.exists())

    def test_cancelled_counts_and_unreadable_record_does_not_stop_the_sweep(self):
        task_dir = self.task("a" * 16, state="cancelled")
        repo = self.clone(task_dir)
        broken = self.root / ("c" * 16)
        broken.mkdir()
        (broken / "task.json").write_text("{not json")
        out = self.run_prune("--terminal", "--apply", ok=False)
        self.assertEqual((out["skipped"], out["deleted"]), ({"unreadable": 1}, 1))
        self.assertFalse(repo.exists())

    def test_refused_nested_worktree_keeps_the_enclosing_checkout(self):
        task_dir = self.task("a" * 16)
        outer = self.clone(task_dir, "outer")
        with (outer / ".git" / "info" / "exclude").open("a") as exclude:
            exclude.write("nested/\n")
        nested = outer / "nested"
        git(self.tmp, "clone", "-q", str(self.origin), str(nested))
        linked = task_dir / "attempt-1" / "wt"
        git(nested, "worktree", "add", "-q", "--detach", str(linked))
        git(nested, "worktree", "lock", str(linked))
        self.run_prune("a" * 16, "--apply", ok=False)
        self.assertTrue(outer.exists() and nested.exists() and linked.exists())
        git(linked, "status")

    def test_cache_holding_borrowed_objects_stays(self):
        task_dir = self.task("a" * 16)
        cache = task_dir / "attempt-1" / "cargo-git"
        cache.mkdir(parents=True)
        (cache / "CACHEDIR.TAG").write_text("Signature: 8a477f597d28d172789f06886806bc55\n")
        source = cache / "checkout"
        git(self.tmp, "clone", "-q", str(self.origin), str(source))
        borrower = task_dir / "attempt-1" / "borrower"
        git(self.tmp, "clone", "-q", "--shared", str(source), str(borrower))
        (borrower / "probe.rs").write_text("untracked\n")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual((out["caches"], out["deleted"]), (0, 0))
        git(borrower, "fsck", "--connectivity-only")

    def test_dirty_submodule_alone_does_not_block_the_parent_save(self):
        task_dir = self.task("a" * 16, ended_days_ago=8)
        parent = self.clone(task_dir, "parent")
        git(parent, "-c", "protocol.file.allow=always", "submodule", "add", "-q",
            str(self.origin), "sub")
        git(parent, "commit", "-qm", "add submodule")
        git(parent, "push", "-q", "origin", "HEAD:main")
        (parent / "sub" / "a.txt").write_text("edited inside the submodule\n")
        out = self.run_prune("a" * 16, "--apply")
        self.assertEqual((out["deleted"], out["errors"]), (1, 0), out)
        saved = task_dir / "pruned" / "attempt-1" / "parent" / "sub" / "tracked.diff"
        self.assertIn("+edited inside the submodule", saved.read_text())

    def test_change_after_save_keeps_the_checkout(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import prune
        task_dir = self.task("a" * 16, ended_days_ago=8)
        repo = self.clone(task_dir)
        (repo / "a.txt").write_text("first edit\n")
        original = prune.save

        def save_then_edit(*args):
            dest = original(*args)
            (repo / "a.txt").write_text("first edit\nsecond edit after the save\n")
            return dest

        prune.save = save_then_edit
        self.addCleanup(setattr, prune, "save", original)
        args = type("Args", (), {"apply": True, "unsaved_after_days": 7})()
        task = json.loads((task_dir / "task.json").read_text())
        result = prune.prune_task(task_dir, task, args, self.root,
                                  datetime.now(timezone.utc), set())
        self.assertTrue(repo.exists(), "the edit made after the save was deleted")
        self.assertIn("second edit", (repo / "a.txt").read_text())
        self.assertEqual([e["error"] for e in result["errors"]], ["changed since inspection"])

    def test_second_run_while_locked_does_nothing(self):
        task_dir = self.task("a" * 16)
        repo = self.clone(task_dir)
        with (self.root / ".prune.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            out = self.run_prune("--terminal", "--apply")
        self.assertEqual(out["status"], "busy")
        self.assertTrue(repo.exists())

    def test_missing_task_is_an_error(self):
        out = self.run_prune("b" * 16, ok=False)
        self.assertEqual(out["skipped"], {"missing": 1})


if __name__ == "__main__":
    unittest.main()
