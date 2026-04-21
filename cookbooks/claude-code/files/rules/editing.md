# File Editing Guidelines

## After `git mv`, Re-Read files before editing

The Edit tool tracks Read history by path, not inode. After `git mv <old> <new>`, the Read cache for `<old>` does NOT carry over to `<new>` — Edit calls on the new path fail with "File has not been read yet", even though the file content is identical and the inode is unchanged.

**Bulk rename workflow:**

1. `git mv` all files first (single Bash call)
2. Re-Read every moved file at its new path — batch in a single message with parallel Read calls
3. Apply Edits

Skipping step 2 produces one "not been read" error per file, scattering across tool calls and wasting context. On a 13-file rename this costs a full round-trip of failed Edits before the re-Read batch can start.

## Multiple Edits on the same file: serialize across messages

If two `Edit` calls target the same file in a single parallel batch, they may race: both read the pre-edit content, both write, last-writer-wins (prior edits are silently lost). Avoid this by:

- Using `replace_all: true` on a single Edit when the pattern allows, OR
- Sending same-file Edits across separate messages (one Edit per message for that file)

Different-file Edits can safely run in parallel in a single message.
