# Rollback fixture provenance

`python-era.tar.gz` is an unmodified `git archive` of session-search commit
`527735d` (the A1 Python implementation). Its full Git tree is
`f4a278a13411d08dc50843d3cdb9f3385d722ed1`. The rollback test reconstructs that
tree and checks its OID before making synthetic history. Regenerate with:

```sh
git -C /path/to/session-search archive --format=tar 527735d | gzip -n > python-era.tar.gz
```

No vendored source is edited. Later fixture commits add only a Cargo marker
and copies of the real S0 corpus; fake release binaries are test executables,
never production artifacts. `test_rollback.py` exercises the real deployment,
recipe, manifest and pin-check entrypoints against that history.
