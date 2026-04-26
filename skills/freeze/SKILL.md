---
name: freeze
description: |
  Restrict file edits to a specific directory for the session. Blocks Edit and
  Write outside the allowed path. Use when debugging to prevent accidentally
  "fixing" unrelated code, or when you want to scope changes to one module.
  Use when asked to "freeze", "restrict edits", "only edit this folder",
  or "lock down edits".
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
hooks:
  PreToolUse:
    - matcher: "Edit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR}/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
    - matcher: "Write"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR}/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
triggers:
  - freeze edits to directory
  - lock editing scope
  - restrict file changes
  - only edit this folder
---

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

The hook reads `file_path` from each Edit/Write call and checks whether the path
starts with the frozen directory. If not, it returns `permissionDecision: "deny"`.

The freeze boundary persists for the session via `~/.vibestack/freeze-dir.txt`.

## Notes

- The trailing `/` prevents `/src` from matching `/src-old`
- Applies to Edit and Write tools only — Read, Bash, Glob, Grep are unaffected
- Bash commands like `sed -i` can still modify files outside the boundary
- To deactivate: run `/unfreeze` or end the conversation
