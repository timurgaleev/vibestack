---
name: context-restore
description: |
  Restore working context saved earlier by /context-save. Loads the most recent saved state for the current branch (falling back to any branch) so you can pick up where you left off — even across Conductor workspace handoffs.
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - AskUserQuestion
triggers:
  - resume where i left off
  - restore context
  - where was i
  - pick up where i left off
  - context restore
---

## When to invoke

Use when asked to "resume", "restore context", "where was I", or "pick up where I left off". Pair with /context-save. Formerly /checkpoint resume — renamed because Claude Code treats /checkpoint as a native rewind alias in current environments.

## Preamble

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.vibestack/bin/vibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

# /context-restore — Restore Saved Working Context

You are a **Staff Engineer reading a colleague's meticulous session notes** to
pick up exactly where they left off. Your job is to load the most recent saved
context and present it clearly so the user can resume work without losing a beat.

**HARD GATE:** Do NOT implement code changes. This skill only reads saved
context files and presents the summary.

**Default: load the most recent context saved on the CURRENT branch; if this
branch has none, fall back to the most recent across ALL branches.** Every
worktree of a repo shares one checkpoints directory, so without the preference a
sibling worktree's newer save would be presented as "where you left off". The
fallback keeps Conductor workspace handoff working — a context saved on one
branch can still be resumed from another.

**Do NOT hard-filter the candidate set to the current branch.** Other-branch
files stay in the set; they are ordered *after* the current branch's own.
(`/context-save list` is the flow that scopes to one branch.)

---

## Detect command

Parse the user's input:

- `/context-restore` → load the most recent saved context (current branch first, then any branch)
- `/context-restore <title-fragment-or-number>` → load a specific saved context
- `/context-restore list` → tell the user "Use `/context-save list` — listing
  lives on the save side" and exit. No mode detection here.

---

## Restore flow

### Step 1: Find saved contexts

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" && mkdir -p ~/.vibestack/projects/$SLUG
CHECKPOINT_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/checkpoints"
if [ ! -d "$CHECKPOINT_DIR" ]; then
  echo "NO_CHECKPOINTS"
else
  # Use find + sort instead of ls -1t. Two reasons:
  # 1. Canonical order is the filename YYYYMMDD-HHMMSS prefix (stable across
  #    copies/rsync). Filesystem mtime drifts and is not authoritative.
  # 2. On macOS, `find ... | xargs ls -1t` with zero results falls back to
  #    listing cwd. `sort -r` on empty input cleanly returns nothing.
  # Scan the 200 newest so a current-branch save sitting below a burst of
  # sibling-worktree saves is still found; the printed list is capped at 20.
  ALL=$(find "$CHECKPOINT_DIR" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort -r | head -200)
  # Drop checkpoints stamped for another project (a different remote, or a
  # different root when neither has one). Each is named, never loaded.
  if [ -n "$ALL" ]; then
    CLASSIFIED=$(printf '%s\n' "$ALL" | ~/.vibestack/bin/vibe-slug --classify-checkpoints 2>/dev/null)
    TAB=$(printf '\t')
    if [ -n "$CLASSIFIED" ] && ! printf '%s\n' "$CLASSIFIED" | grep -qvE "^(match|unstamped|foreign)${TAB}"; then
      printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "foreign" { print $2 }' | while IFS= read -r f; do
        echo "PROJECT MISMATCH: $f ($(grep -m1 '^remote:' "$f" 2>/dev/null), $(grep -m1 '^project_root:' "$f" 2>/dev/null))"
      done
      ALL=$(printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 != "foreign" { print $2 }')
    else
      echo "IDENTITY_CHECK_UNAVAILABLE"
    fi
  fi
  if [ -z "$ALL" ]; then
    echo "NO_CHECKPOINTS"
  else
    # Current-branch files first, other branches after, each newest first.
    # CURRENT_BRANCH may be preset; otherwise it comes from git.
    : "${CURRENT_BRANCH:=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
    SAME=""; OTHER=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b=$(grep -m1 '^branch:' "$f" 2>/dev/null | sed 's/^branch:[[:space:]]*//')
      if [ -n "$CURRENT_BRANCH" ] && [ "$b" = "$CURRENT_BRANCH" ]; then
        SAME="${SAME}${f}
"
      else
        OTHER="${OTHER}${f}
"
      fi
    done <<EOF
$ALL
EOF
    echo "CURRENT_BRANCH=${CURRENT_BRANCH:-unknown}"
    [ -n "$SAME" ] || echo "NO_CURRENT_BRANCH_CHECKPOINT"
    # Named separately: with 20+ saves on this branch the capped list below
    # would never reach another branch's newer save.
    [ -n "$SAME" ] && [ -n "$OTHER" ] && echo "NEWEST_OTHER: $(printf '%s' "$OTHER" | head -1)"
    # Cap at 20: a user with 10k saved files shouldn't blow the context window
    # just listing them. /context-save list handles pagination.
    printf '%s%s' "$SAME" "$OTHER" | grep -v '^[[:space:]]*$' | head -20
  fi
fi
```

**Candidates include every `.md` file in the directory**, ordered
**current-branch-first** (the branch is read from each file's `branch:`
frontmatter). Other-branch files stay in the set as the fallback, which keeps
Conductor workspace handoff working when this branch has no save of its own.
`NO_CURRENT_BRANCH_CHECKPOINT` means every path printed came from another branch.

**Project identity.** `/context-save` stamps each checkpoint with `remote:` (the
credential-free origin) and `project_root:`. A checkpoint stamped for a
different project is never a candidate: Step 1 prints `PROJECT MISMATCH: <path>
(...)` for it instead. Report every `PROJECT MISMATCH` line to the user **before
any summary**, e.g. "Skipped 1 checkpoint saved for `github.com/bob/api` — it
belongs to another project." If that leaves no candidate (`NO_CHECKPOINTS`),
say the bucket holds only other projects' saves. Never load a mismatched file,
even when the user names it by title or number — name its project and stop.
Checkpoints with no `remote:` field were saved before stamping existed; they
stay candidates. `IDENTITY_CHECK_UNAVAILABLE` means the installed `vibe-slug`
cannot classify checkpoints — say identity was not checked and suggest
`/vibe-upgrade`.

### Step 2: Load the right file

- If the user specified a title fragment or number: find the matching file among
  the candidates.
- Otherwise: load the **first path printed by Step 1** — the newest
  `YYYYMMDD-HHMMSS` save on the current branch or, when Step 1 printed
  `NO_CURRENT_BRANCH_CHECKPOINT`, the newest across all branches.

**Sort Remaining Work by provenance.** `/context-save` ends each item with a
marker saying how that session knew it. Keep every item's original text and
saved order, and drop nothing. An item's marker is the last provenance marker in
it, and it counts as the ending even when an outcome follows it: older saves
wrote `Open. Run the suite. (path run) exit 0`, current ones write
`Open. Run the suite, exit 0. (path run)`, and both are `(path run)` with a
successful outcome. Put an item under **Verify first** when it:
- ends in `(path assumed)` or `(code read)`;
- ends in `(path run)` but its text reports a failure;
- has no marker and is a writing step (migration, sync, insert, import, deploy,
  a dialog that writes) or names a concrete path (a runnable command, CLI flag or
  switch, config key or value, or file or directory path).

Every other item goes under **Next steps**: `(path run)` with a successful
outcome, `(path read)`, `(target state checked)`, and unmarked items that neither
write nor name a concrete path. Verifying means read-only inspection: read the
file or the target, or run a command that changes nothing. Saves written before
provenance markers existed have none, so their concrete-path and writing items
land under Verify first. When the file has no provenance markers at all, print
this line above the groups:
`This checkpoint predates provenance markers; items naming commands, paths or writes are listed under Verify first.`

Read the chosen file and present a summary:

```
RESUMING CONTEXT
════════════════════════════════════════
Title:       {title}
Branch:      {branch from frontmatter}
Saved:       {timestamp, human-readable}
Duration:    Last session was {formatted duration} (if available)
Status:      {status}
════════════════════════════════════════

### Summary
{summary from saved file}

### Remaining Work
{legacy banner line, if it applies}

Next steps
{Next steps items, in saved order, original text}

Verify first (inspect read-only before executing anything)
{Verify first items, in saved order, original text}

### Notes
{notes}
```

If the loaded file has no `remote:` field, add one line under the header box:
"This checkpoint predates project stamps; confirm it belongs to this project."

If the current branch differs from the saved context's branch, note this:
"This context was saved on branch `{branch}`. You are currently on
`{current branch}`. You may want to switch branches before continuing."

If the loaded file is the current branch's but the `NEWEST_OTHER:` path from Step 1
(the newest save from another branch) has a newer timestamp, name it: "There is also a newer context saved on
`{other branch}` — `{title}` from `{timestamp}`. Load that one instead?" A
Conductor handoff to this branch shows up that way, and the user decides.

### Step 3: Offer next steps

After presenting, ask via AskUserQuestion:

- A) Continue working on the remaining items
- B) Show the full saved file
- C) Just needed the context, thanks

If A, take the first Remaining Work item in saved order. If it is under Next
steps, suggest starting there. If it is under Verify first, suggest verifying it
read-only before doing it or any later item, so a later runnable step never
jumps ahead of an unverified earlier one. Never execute a Verify first item as
part of the restore.

---

## If no saved contexts exist

If Step 1 printed `NO_CHECKPOINTS`, tell the user:

"No saved contexts yet. Run `/context-save` first to save your current working
state, then `/context-restore` will find it."

---

## Important Rules

- **Never modify code.** This skill only reads saved files and presents them.
- **Prefer the current branch's own save, but keep all branches in the
  fallback set.** Cross-branch resume (Conductor handoff) works when this branch
  has no save, and a sibling worktree's newer save never shadows this branch's.
- **Another project's checkpoint is never restored.** A `PROJECT MISMATCH`
  file is reported and skipped, never presented as "where you left off".
- **Unverified steps are shown, not run.** An item under Verify first was
  guessed or failed in the saved session; inspect before acting on it.
- **"Most recent" means the filename `YYYYMMDD-HHMMSS` prefix**, not
  `ls -1t` (filesystem mtime). Filenames are stable across file-system
  operations; mtime is not.
- **This is a vibestack skill, not a Claude Code built-in.** When the user types
  `/context-restore`, invoke this skill via the Skill tool.
