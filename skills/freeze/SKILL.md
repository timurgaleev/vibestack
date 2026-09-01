---
name: freeze
description: |
  Restrict file edits to a specific directory for the session. Blocks Edit and Write outside the allowed path.
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
triggers:
  - freeze edits to directory
  - lock editing scope
  - restrict file changes
  - only edit this folder
---

## When to invoke

Use when debugging to prevent accidentally "fixing" unrelated code, or when you want to scope changes to one module. Use when asked to "freeze", "restrict edits", "only edit this folder", or "lock down edits".

# /freeze — Restrict Edits to a Directory

Lock file edits to a specific directory. Any Edit or Write operation targeting
a file outside the allowed path will be **blocked** (not just warned).

## Setup

Ask the user which directory to restrict edits to:

> "Which directory should I restrict edits to? Files outside this path will be blocked from editing."

Once the user provides a path:

```bash
FREEZE_DIR=$(cd "<user-provided-path>" 2>/dev/null && pwd)
FREEZE_DIR="${FREEZE_DIR%/}/"
STATE_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}"
mkdir -p "$STATE_DIR"
echo "$FREEZE_DIR" > "$STATE_DIR/freeze-dir.txt"
echo "Freeze boundary set: $FREEZE_DIR"
```

Tell the user: "Edits are now restricted to `<path>/`. Any Edit or Write
outside this directory will be blocked. To change the boundary, run `/freeze`
again. To remove it, run `/unfreeze`."

## How it works

The hook parses `file_path` out of each Edit/Write payload, resolves the path
fully — including a final component that is itself a symlink — and checks whether
it starts with the frozen directory. If not, it returns a `hookSpecificOutput`
envelope carrying `permissionDecision: "deny"`. The nesting matters: Claude Code
ignores a top-level `permissionDecision`, so a deny emitted at the top level lets
the edit through.

Freeze is the **deny tier**, so it fails closed: a payload it cannot parse is
blocked, not allowed. Its ask-tier sibling `/careful` makes the opposite call on
the same input. Both share one extractor (`careful/bin/hook-extract.sh`).

The freeze boundary persists for the session via `~/.vibestack/freeze-dir.txt`.

## Notes

- The trailing `/` prevents `/src` from matching `/src-old`
- Applies to Edit and Write tools only — Read, Bash, Glob, Grep are unaffected
- Bash commands like `sed -i` can still modify files outside the boundary
- A symlink inside the boundary pointing outside it is resolved and blocked
- A path with spaces in it works — only leading and trailing whitespace is
  trimmed from the saved boundary, and a leading `~` is expanded
- To deactivate: run `/unfreeze` or end the conversation
