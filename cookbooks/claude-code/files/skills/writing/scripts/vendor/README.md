# vendor/

Third-party files bundled unmodified for `../slop_scan.py`.

| File | Upstream | Commit | Imported |
|---|---|---|---|
| `yomiyasu_lint.py` | https://github.com/nanaism/yomiyasu `scripts/yomiyasu_lint.py` | 8d5abeebe2dd20c2db005deaddcc50be43c59c0a | 2026-10-03 |
| `LICENSE-yomiyasu` | https://github.com/nanaism/yomiyasu `LICENSE` (MIT, © 2026 nanaism) | 8d5abeebe2dd20c2db005deaddcc50be43c59c0a | 2026-10-03 |

## Rules

- Never edit these files. They must stay byte-identical to upstream (`cmp` against a clone at the recorded commit).
- To update: replace the file with the new upstream version, update the commit and date in the table above, then run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s . -p 'test_*.py' -v` from `scripts/` (this directory's parent), and confirm the summary line reports a non-zero test count — `Ran 0 tests` means discovery pointed at the wrong directory and nothing was checked. `test_slop_scan.py` pins the rule ids `slop_scan.py` keeps and drops; an upstream rename shows up there as a failure or as an entry in `dropped_rules`.
- `slop_scan.py` uses only these vendor rules: `metaphor_verb`, `slop_vocabulary` (pathology 1), `negative_parallelism`, `excess_bold`, `excess_list`, `emoji_prohibited` (pathology 3), `meta_filler`. Every other rule is dropped from its output.

Attribution: nanaism/yomiyasu（MIT, © 2026 nanaism, @8d5abeeb）
