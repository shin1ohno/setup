#!/usr/bin/env python3
"""Reclaim rebuildable checkouts and caches from terminal chief-of-staff tasks.

Removes git checkouts that hold no unsaved work, directories carrying a signed
CACHEDIR.TAG, and node_modules. A checkout with unsaved work stays until its
task has been terminal for --unsaved-after-days; then its tracked diff, its
untracked file list and a bundle of its unpushed refs are saved under
<task>/pruned/ and verified before it goes. Task records, briefs, reports and
logs always stay. Anything git cannot answer for is kept. Dry-run unless --apply.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tasks import TERMINAL, root_dir  # noqa: E402

DAY = 86400
REMOVABLE = ("delete", "save")
CACHEDIR_SIGNATURE = b"Signature: 8a477f597d28d172789f06886806bc55"
DIFF = ["diff", "--binary", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty",
        "--src-prefix=a/", "--dst-prefix=b/"]
# Inherited repository-location variables would point every call at one repository.
GIT_ENV = {k: v for k, v in os.environ.items() if k not in {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES"}}
GIT_ENV["GIT_OPTIONAL_LOCKS"] = "0"


def git(repo, *args, out=None):
    """Return stdout as text ("" when streamed to out), or None when git fails."""
    try:
        proc = subprocess.run(["git", "-c", "core.quotePath=false", "-C", str(repo), *args],
                              env=GIT_ENV, timeout=600,
                              stdout=out or subprocess.PIPE, stderr=subprocess.PIPE)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode:
        return None
    return "" if out else proc.stdout.decode("utf-8", "replace")


def inside(child, parent):
    return child == parent or parent in child.parents


def live_cwds():
    """Working directories of this user's processes, or None when unreadable."""
    if Path("/proc").is_dir():
        cwds = set()
        for pid in os.listdir("/proc"):
            if pid.isdigit():
                try:
                    cwds.add(Path(os.readlink(f"/proc/{pid}/cwd").removesuffix(" (deleted)")))
                except OSError:
                    pass
        return cwds
    try:
        proc = subprocess.run(["lsof", "-w", "-d", "cwd", "-Fn"], capture_output=True,
                              text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    cwds = {Path(line[1:]) for line in proc.stdout.splitlines() if line.startswith("n/")}
    return cwds or None


def borrowed_object_dirs(root):
    """Object directories other repositories under root depend on, with the reason.

    Two ways to depend on another repository's objects: objects/info/alternates
    (a `git clone --shared`), and a partial clone whose promisor remote is a local
    path, which fetches missing blobs from it on demand.
    """
    for _ in range(2):  # a directory removed mid-walk fails find once
        proc = subprocess.run(["find", str(root), "-type", "f", "(",
                               "-path", "*/objects/info/alternates", "-o",
                               "-path", "*.git/config", ")"], capture_output=True, text=True)
        if proc.returncode == 0:
            break
    else:
        return None
    borrowed = {}
    for name in proc.stdout.splitlines():
        path = Path(name)
        try:
            text = path.read_text(errors="replace")
        except FileNotFoundError:
            continue
        if path.name == "alternates":
            for line in text.splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    borrowed[(path.parent.parent / line).resolve()] = "alternates-source"
        elif "promisor" in text.lower() or "partialclone" in text.lower():
            for source in local_promisors(path):
                for objects in (source / ".git" / "objects", source / "objects"):
                    borrowed.setdefault(objects.resolve(), "promisor-source")
    return borrowed


def local_promisors(config):
    """Local-path promisor remotes named in one repository's config file."""
    listing = git(config.parent, "config", "-f", str(config), "--get-regexp",
                  r"^(remote\..*\.(promisor|url)|extensions\.partialclone)$")
    remotes, urls = set(), {}
    for line in (listing or "").splitlines():
        key, _, value = line.partition(" ")
        if key == "extensions.partialclone":
            remotes.add(value)
        elif key.endswith(".promisor") and value.lower() in ("true", "yes", "on", "1"):
            remotes.add(key[len("remote."):-len(".promisor")])
        elif key.endswith(".url"):
            urls[key[len("remote."):-len(".url")]] = value
    # git resolves a relative local URL from the work tree, or the git dir of a bare repository.
    base = config.parent.parent if config.parent.name == ".git" else config.parent
    for remote in remotes:
        url = urls.get(remote, "")
        if url.startswith("file://"):
            url = url[len("file://"):]
        elif "://" in url or re.match(r"^[^/]+:", url):
            continue  # network remote: the objects live elsewhere
        if url:
            yield (base / url).resolve()


def terminal_at(task):
    """When the task first entered a terminal state, from its history."""
    for entry in task.get("history") or []:
        if entry.get("state") in TERMINAL:
            try:
                at = datetime.fromisoformat(entry["at"])
            except (KeyError, TypeError, ValueError):
                return None
            return at if at.tzinfo else at.replace(tzinfo=timezone.utc)
    return None


def protected(path, task_dir):
    """Paths that hold the task's own records and are never removed whole."""
    return (path == task_dir or inside(path, task_dir / "pruned")
            or (path.parent == task_dir and path.name.startswith("attempt-")))


def signed_cache(directory):
    try:
        with (directory / "CACHEDIR.TAG").open("rb") as tag:
            signed = tag.read(len(CACHEDIR_SIGNATURE)) == CACHEDIR_SIGNATURE
    except OSError:
        return False
    return signed and not (directory / ".git").exists()


def scan(task_dir):
    """Repositories and caches in the task, or None when the walk was incomplete."""
    proc = subprocess.run(["find", str(task_dir),
                           "-name", "node_modules", "-type", "d", "-prune", "-print",
                           "-o", "-name", ".git", "-print", "-prune",
                           "-o", "-name", "CACHEDIR.TAG", "-type", "f", "-print"],
                          capture_output=True, text=True)
    if proc.returncode:
        return None
    repos, caches = [], []
    for line in proc.stdout.splitlines():
        path = Path(line)
        if path.name == ".git":
            repos.append(path.parent)
        elif path.name == "node_modules":
            caches.append(path)
        elif signed_cache(path.parent):
            caches.append(path.parent)
    caches = [c for c in caches if not protected(c, task_dir)]
    caches = [c for c in caches if not any(o != c and inside(c, o) for o in caches)]
    # A tagged directory declares everything below it regenerable, including the
    # git checkouts Cargo keeps under its git cache.
    repos = [r for r in repos if not inside(r, task_dir / "pruned")
             and not any(inside(r, c) for c in caches)]
    return repos, caches


def fingerprint(repo):
    """Digest of everything removal would lose; it must not change before removal."""
    head = git(repo, "rev-parse", "--verify", "-q", "HEAD")
    diffs = [[*DIFF, "HEAD"]] if head else [[*DIFF, "--cached"], DIFF]
    parts = [git(repo, "status", "--porcelain", "--untracked-files=normal"), head or "unborn",
             git(repo, "for-each-ref", "--format=%(objectname) %(refname)"),
             *(git(repo, *d) for d in diffs),
             git(repo, "ls-files", "--others", "--exclude-standard")]
    if None in parts:
        return None
    digest = hashlib.sha256("\0".join(parts).encode())
    for name in parts[-1].splitlines():
        try:
            st = os.lstat(repo / name)
        except OSError:
            return None
        digest.update(f"{name}\0{st.st_size}\0{st.st_mtime_ns}\0".encode())
    return digest.hexdigest()


def inspect(repo, task_dir, borrowed):
    info = {"linked": False, "common": None, "head": None, "blocker": None, "unsaved": [],
            "fingerprint": None}
    dirs = git(repo, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir")
    if dirs is not None and len(dirs.splitlines()) == 2:
        git_dir, common = (str(Path(p).resolve()) for p in dirs.splitlines())
        info["common"] = common
        # A linked worktree has its own git dir under the common one; a submodule does not.
        info["linked"] = git_dir != common
    if protected(repo, task_dir):
        info["blocker"] = "task-or-attempt-root"
        return info
    if repo.is_symlink() or repo.resolve() != repo:
        info["blocker"] = "symlink"
        return info
    if info["common"] is None:
        info["blocker"] = "git-error"
        return info
    lender = borrowed.get((Path(info["common"]) / "objects").resolve())
    if lender:
        info["blocker"] = lender
        return info
    status = git(repo, "status", "--porcelain", "--untracked-files=normal")
    if status is None:
        info["blocker"] = "git-error"
        return info
    lines = status.splitlines()
    if any(not line.startswith("??") for line in lines):
        info["unsaved"].append("dirty")
    if any(line.startswith("??") for line in lines):
        info["unsaved"].append("untracked")
    head = git(repo, "rev-parse", "--verify", "-q", "HEAD")
    if head:
        info["head"] = head.strip()
    else:
        branch = git(repo, "symbolic-ref", "-q", "HEAD")
        exists = branch and git(repo, "for-each-ref", "--count=1", branch.strip())
        if not branch or exists is None or exists.strip():
            info["blocker"] = "git-error"
            return info
        info["unsaved"].append("unborn-head")
    tip = ["HEAD"] if info["head"] else []
    if info["linked"]:
        # Branches and the stash live in the common repository, which this removal keeps.
        unpushed = git(repo, "rev-list", "-n1", *tip, "--not", "--remotes", "--branches")
    else:
        stash = git(repo, "for-each-ref", "--count=1", "refs/stash")
        worktrees = git(repo, "worktree", "list", "--porcelain")
        unpushed = git(repo, "rev-list", "-n1", "--branches", *tip, "--not", "--remotes")
        if stash is None or worktrees is None:
            info["blocker"] = "git-error"
            return info
        if stash.strip():
            info["unsaved"].append("stash")
        for line in worktrees.splitlines():
            if line.startswith("worktree "):
                other = Path(line[len("worktree "):])
                if other != repo and other.exists() and not inside(other, task_dir):
                    info["blocker"] = "external-worktree"
                    return info
    if unpushed is None:
        info["blocker"] = "git-error"
        return info
    if unpushed.strip():
        info["unsaved"].append("unpushed")
    info["fingerprint"] = fingerprint(repo)
    if info["fingerprint"] is None:
        info["blocker"] = "git-error"
    return info


def settle(info, decision):
    """Keep a checkout when one nested in it, around it, or sharing its repository is kept."""
    changed = True
    while changed:
        changed = False
        kept = [r for r, d in decision.items() if d not in REMOVABLE]
        for repo, d in decision.items():
            if d in REMOVABLE and any(
                    k != repo and (inside(k, repo) or inside(repo, k) or info[k]["common"] is None
                                   or info[k]["common"] == info[repo]["common"])
                    for k in kept):
                decision[repo] = "shares-kept-repo"
                changed = True


def only_gitlinks(repo):
    """True when every tracked change is a submodule, which is inspected on its own."""
    status = git(repo, "status", "--porcelain", "--untracked-files=no")
    if not status:
        return False
    for line in status.splitlines():
        entry = git(repo, "ls-files", "-s", "--", line[3:].split(" -> ")[-1])
        if not entry or not entry.startswith("160000 "):
            return False
    return True


def save(repo, info, task_dir, now):
    """Save and verify what deleting this checkout would lose; return the folder or None."""
    dest = task_dir / "pruned" / repo.relative_to(task_dir)
    try:
        dest.mkdir(mode=0o700, parents=True, exist_ok=True)
        files = []
        if "dirty" in info["unsaved"]:
            if info["head"]:
                diffs = [("tracked.diff", [*DIFF, "HEAD"], [])]
            else:
                diffs = [("staged.diff", [*DIFF, "--cached"], ["--cached"]),
                         ("unstaged.diff", DIFF, [])]
            for name, command, check in diffs:
                path = dest / name
                with path.open("wb") as handle:
                    if git(repo, *command, out=handle) is None:
                        return None
                if path.stat().st_size == 0:
                    path.unlink()
                    continue
                # The tree must be exactly HEAD plus this diff: undoing it has to apply cleanly.
                if git(repo, "apply", "--check", "-R", *check, str(path)) is None:
                    return None
                files.append(name)
            if not files and not only_gitlinks(repo):
                return None
        if "untracked" in info["unsaved"]:
            with (dest / "untracked.txt").open("wb") as handle:
                if git(repo, "ls-files", "--others", "--exclude-standard", out=handle) is None:
                    return None
            files.append("untracked.txt")
        if {"unpushed", "stash"} & set(info["unsaved"]):
            tip = ["HEAD"] if info["head"] else []
            refs = tip if info["linked"] else ["--branches", "--tags", *tip] + (
                ["refs/stash"] if "stash" in info["unsaved"] else [])
            bundle = dest / "unpushed.bundle"
            if git(repo, "bundle", "create", str(bundle), *refs, "--not", "--remotes") is None:
                return None
            if git(repo, "bundle", "verify", str(bundle)) is None:
                return None
            files.append("unpushed.bundle")
        manifest = {"repo": str(repo), "saved_at": now.isoformat(timespec="seconds"),
                    "reasons": info["unsaved"], "head": info["head"],
                    "branch": (git(repo, "branch", "--show-current") or "").strip() or None,
                    "remotes": (git(repo, "remote", "-v") or "").splitlines(),
                    "files": files,
                    "not_kept": "untracked file contents; ignored files"}
        (dest / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    except OSError:
        return None
    return dest


def removable(path, root, task_dir):
    try:
        same_device = os.lstat(path).st_dev == os.lstat(task_dir).st_dev
    except OSError:
        return False
    return (same_device and not path.is_symlink() and path.resolve() == path
            and inside(path, task_dir) and not protected(path, task_dir)
            and len(path.relative_to(root).parts) >= 2 and one_filesystem(path))


def one_filesystem(path):
    """rmtree would cross into anything mounted below path; refuse that."""
    device = os.lstat(path).st_dev
    for current, _dirs, _files in os.walk(path):
        try:
            if os.lstat(current).st_dev != device:
                return False
        except OSError:
            return False
    return True


def remove(path, info, root, task_dir, force):
    if not removable(path, root, task_dir):
        return "refused by path guard"
    if info and info["linked"]:
        # git refuses a locked or changed worktree; that refusal stands.
        proc = subprocess.run(["git", "--git-dir", info["common"], "worktree", "remove",
                               *(["--force"] if force else []), str(path)],
                              env=GIT_ENV, capture_output=True, text=True)
        return None if proc.returncode == 0 else (proc.stderr.strip() or "worktree remove failed")
    try:
        shutil.rmtree(path)
    except OSError as error:
        return str(error)
    return None


def prune_task(task_dir, task, args, root, now, borrowed):
    result = {"task": task_dir.name, "repos": [], "save": [], "caches": [], "kept": [],
              "deleted": [], "saved": {}, "errors": []}
    scanned = scan(task_dir)
    if scanned is None:
        result["errors"].append({"path": str(task_dir), "error": "incomplete directory walk"})
        return result
    repos, caches = scanned
    # A cache holding objects another repository borrows stays with them.
    caches = [c for c in caches if not any(inside(b, c) for b in borrowed)]
    info = {r: inspect(r, task_dir, borrowed) for r in repos}
    since = terminal_at(task)
    aged = since is not None and (now - since).total_seconds() >= args.unsaved_after_days * DAY
    decision = {}
    for repo, i in info.items():
        if i["blocker"]:
            decision[repo] = i["blocker"]
        elif not i["unsaved"]:
            decision[repo] = "delete"
        elif aged:
            decision[repo] = "save"
        else:
            decision[repo] = "unsaved-age-unknown" if since is None else "unsaved-recent"
    settle(info, decision)
    top, drop_caches = [], []
    try:
        if args.apply:
            for repo in sorted(r for r, d in decision.items() if d == "save"):
                dest = save(repo, info[repo], task_dir, now)
                if dest is None:
                    decision[repo] = "save-failed"
                    result["errors"].append({"path": str(repo),
                                             "error": "save or verification failed"})
                else:
                    result["saved"][str(repo)] = str(dest)
            settle(info, decision)
        chosen = [r for r, d in decision.items() if d in REMOVABLE]
        top = [r for r in chosen if not any(o != r and inside(r, o) for o in chosen)]
        drop_caches = [c for c in caches if not any(inside(c, r) for r in top)]
        if args.apply:
            remove_all(task_dir, root, info, decision, top, drop_caches, result)
    except Exception as error:  # record what was already removed before giving up on the task
        result["errors"].append({"path": str(task_dir), "error": repr(error)})
    result["repos"] = [str(r) for r in top]
    result["save"] = sorted(str(r) for r, d in decision.items() if d == "save")
    result["caches"] = [str(c) for c in drop_caches]
    result["kept"] = [{"path": str(r), "reason": d, "unsaved": info[r]["unsaved"]}
                      for r, d in sorted(decision.items()) if d not in REMOVABLE]
    if args.apply and (result["deleted"] or result["saved"] or result["errors"]):
        stamp = now.strftime("%Y%m%dT%H%M%SZ")
        (task_dir / f"pruned-{stamp}.json").write_text(json.dumps(result, indent=1) + "\n")
    return result


def remove_all(task_dir, root, info, decision, top, caches, result):
    errors = result["errors"]
    cwds = live_cwds()
    if cwds is None or any(inside(c, task_dir) for c in cwds):
        errors.append({"path": str(task_dir), "error": "in use at removal time"})
        top[:], caches[:] = [], []
        return
    failed = set()
    # Linked worktrees first, so `git worktree remove` still finds their repository.
    for repo in sorted(top, key=lambda r: not info[r]["linked"]):
        held = [r for r in info if inside(r, repo)]  # this checkout and every one nested in it
        if any(not info[r]["linked"] and info[r]["common"] in failed for r in held):
            error = "a worktree of a repository here was not removed"
        elif any(fingerprint(r) != info[r]["fingerprint"] for r in held):
            error = "changed since inspection"
        else:
            error = remove(repo, info[repo], root, task_dir, decision[repo] == "save")
        if error:
            failed.add(info[repo]["common"])
            decision[repo] = "remove-failed"
            errors.append({"path": str(repo), "error": error})
        else:
            result["deleted"].append(str(repo))
    for cache in caches:
        if cache.exists():
            error = remove(cache, None, root, task_dir, False)
            (errors.append({"path": str(cache), "error": error}) if error
             else result["deleted"].append(str(cache)))


def guarded(task_dir, *rest):
    try:
        return prune_task(task_dir, *rest)
    except Exception as error:  # one task's failure must not hide the others' results
        return {"task": task_dir.name, "repos": [], "save": [], "caches": [], "kept": [],
                "deleted": [], "saved": {}, "errors": [{"path": str(task_dir), "error": repr(error)}]}


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("task_ids", nargs="*", metavar="task-id")
    cli.add_argument("--terminal", action="store_true", help="Every accepted or cancelled task")
    cli.add_argument("--apply", action="store_true", help="Delete; without it nothing changes")
    cli.add_argument("--unsaved-after-days", type=int, default=7, metavar="DAYS",
                     help="Save then delete unsaved work this long after the task ended")
    cli.add_argument("--verbose", action="store_true", help="Print every path, not only counts")
    return cli


def main():
    cli = parser()
    args = cli.parse_args()
    if bool(args.task_ids) == args.terminal:
        cli.error("give task IDs or --terminal, not both")
    if args.unsaved_after_days < 0:
        cli.error("--unsaved-after-days must be zero or more")
    for task_id in args.task_ids:
        if not re.fullmatch(r"[a-f0-9]{16}", task_id):
            cli.error(f"invalid task ID: {task_id}")
    root = root_dir()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = (root / ".prune.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(json.dumps({"status": "busy", "detail": "another prune is running"}))
        return 0
    cwds = live_cwds()
    borrowed = borrowed_object_dirs(root)
    if cwds is None or borrowed is None:
        what = ("process working directories" if cwds is None
                else "object sharing under the state root")
        print(json.dumps({"status": "error", "detail": f"cannot read {what}"}))
        return 1
    if args.terminal:
        dirs = sorted(p.parent for p in root.glob("*/task.json"))
    else:
        dirs = [root / task_id for task_id in args.task_ids]
    skipped = {"missing": [], "unreadable": [], "not-terminal": [], "busy": [], "symlink": []}
    work = []
    for task_dir in dirs:
        record = task_dir / "task.json"
        if task_dir.is_symlink() or (task_dir.exists() and task_dir.resolve() != task_dir):
            skipped["symlink"].append(task_dir.name)
            continue
        if not record.is_file():
            skipped["missing"].append(task_dir.name)
            continue
        try:
            task = json.loads(record.read_text())
            state = task.get("state")
        except (OSError, ValueError, AttributeError):
            skipped["unreadable"].append(task_dir.name)
            continue
        if state not in TERMINAL:
            skipped["not-terminal"].append(task_dir.name)
        elif any(inside(c, task_dir) for c in cwds):
            skipped["busy"].append(task_dir.name)
        else:
            work.append((task_dir, task))
    now = datetime.now(timezone.utc)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda item: guarded(*item, args, root, now, borrowed), work))
    reasons = {}
    for result in results:
        for item in result["kept"]:
            reasons[item["reason"]] = reasons.get(item["reason"], 0) + 1
    summary = {
        "status": "ok", "apply": args.apply, "tasks": len(work),
        "skipped": {k: len(v) for k, v in skipped.items() if v},
        "repos": sum(len(r["repos"]) for r in results),
        "save": sum(len(r["save"]) for r in results),
        "caches": sum(len(r["caches"]) for r in results),
        "deleted": sum(len(r["deleted"]) for r in results),
        "kept": reasons,
        "errors": sum(len(r["errors"]) for r in results),
    }
    if args.verbose:
        summary["skipped_tasks"] = {k: v for k, v in skipped.items() if v}
        summary["results"] = [r for r in results if r["repos"] or r["caches"] or r["kept"]
                              or r["errors"]]
    print(json.dumps(summary, indent=1))
    return 1 if summary["errors"] or skipped["missing"] or skipped["unreadable"] else 0


if __name__ == "__main__":
    sys.exit(main())
