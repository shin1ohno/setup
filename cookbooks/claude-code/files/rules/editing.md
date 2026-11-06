# File Editing Guidelines

## After `git mv`, Re-Read files before editing

Detail: see `~/.claude/docs/git-commit-detail.md#git-mv-reread`.

## Multiple Edits on the same file: serialize across messages

If two `Edit` calls target the same file in a single parallel batch, they may race: both read the pre-edit content, both write, last-writer-wins (prior edits are silently lost). Avoid this by:

- Using `replace_all: true` on a single Edit when the pattern allows, OR
- Sending same-file Edits across separate messages (one Edit per message for that file)

Different-file Edits can safely run in parallel in a single message.
