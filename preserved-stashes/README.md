# Preserved stashes

Read-only copies of two `git stash` entries that existed on one machine only.
The stashes themselves are untouched and still in the working clone — this is a
copy, not a move, and it does not undo the decision to set that work aside.

Why: a stash is the easiest thing in git to lose. It is invisible to `git status`,
never pushed by any normal workflow, dropped silently by `git stash clear`, and
gone with the disk. `stash@{1}` had been carrying 24 files for two weeks.

| file | date | subject |
|---|---|---|
| `stash-0.patch` | 2026-09-10 | On master: pre-production-build cleanup |
| `stash-1.patch` | 2026-08-29 | On fix/rauc-custom-boot-attempts: preserve unrelated rauc custom boot attempts work |

Apply with `git apply preserved-stashes/stash-N.patch` on the branch named in the
header. Neither has been reviewed, built or tested by whoever wrote this file;
they are bytes, preserved as found.

Delete this branch once both are either restored or genuinely unwanted.
