---
name: freeze
description: |
  Restrict file edits to one directory until /unfreeze; blocks edits outside the allowed path.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
hooks:
  PreToolUse:
    - matcher: "Edit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/freeze}/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
    - matcher: "Write"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/freeze}/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
    - matcher: "NotebookEdit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/freeze}/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
triggers:
  - freeze edits to directory
  - lock editing scope
  - restrict file changes
  - only edit this folder
---

## When to invoke

Use when debugging to prevent accidentally "fixing" unrelated code, or when you want to scope changes to one module. Use when asked to "freeze", "restrict edits", "only edit this folder", or "lock down edits".

# /freeze — Restrict Edits to a Directory

Lock file edits to a specific directory. Any Edit, Write or NotebookEdit
operation targeting a file outside the allowed path will be **blocked** (not
just warned).

**Where this is enforced.** The block is a Claude Code `PreToolUse` hook.
Cursor, Kiro and Codex install the same skill, but the hook is not guaranteed
to run there; outside Claude Code `/freeze` is instruction-only. On those
hosts, tell the user the boundary is advisory: you will keep your own edits
inside it, but nothing blocks an edit that lands outside.

## Setup

Ask the user which directory to restrict edits to:

> "Which directory should I restrict edits to? Files outside this path will be blocked from editing."

Once the user provides a path, set it with the shared state writer. It
resolves the physical absolute path, refuses a path that does not exist or
resolves to `/`, and writes the state file atomically:

```bash
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/freeze}/bin/freeze-state.sh" set "<user-provided-path>"
```

Report success only if the command exits 0 and prints `FREEZE_DIR=`. On
`FREEZE_ERROR` (a mistyped or missing path, or `/`), tell the user no boundary
was set and ask for the path again. On `FREEZE_BUSY`, another writer holds the
lock — retry once it finishes, and never write or delete the state file
directly.

Tell the user: "Edits are now restricted to `<FREEZE_DIR>/`. Any Edit, Write or
NotebookEdit outside this directory will be blocked. To change the boundary,
run `/freeze` again. To remove it, run `/unfreeze`."

## How it works

The hook parses `file_path` out of each Edit/Write payload (`notebook_path` for
NotebookEdit), resolves the path
fully — including a final component that is itself a symlink — and checks whether
it starts with the frozen directory. If not, it returns a `hookSpecificOutput`
envelope carrying `permissionDecision: "deny"`. The nesting matters: Claude Code
ignores a top-level `permissionDecision`, so a deny emitted at the top level lets
the edit through.

Freeze is the **deny tier**, so it fails closed: a payload it cannot parse, a
payload with no path, a relative saved boundary, and any unexpected hook error
are all blocked, not allowed. Its ask-tier sibling `/careful` makes the opposite call on
the same input. Both share one extractor (`careful/bin/hook-extract.sh`).

The boundary lives in `~/.vibestack/freeze-dir.txt`, not in the session.
Ending or killing a conversation stops its hooks but leaves the file in place,
so the next session that loads the freeze hook (`/freeze`, `/guard`,
`/investigate`) enforces the same boundary again. Only `/unfreeze` removes it.

## Notes

- The trailing `/` prevents `/src` from matching `/src-old`
- Applies to Edit, Write and NotebookEdit only — Read, Bash, Glob, Grep are unaffected
- Bash commands like `sed -i` can still modify files outside the boundary
- A symlink inside the boundary pointing outside it is resolved and blocked
- A path with spaces in it works — only leading and trailing whitespace is
  trimmed from the saved boundary, and a leading `~` is expanded
- To deactivate: run `/unfreeze` — ending the conversation does not remove the boundary
