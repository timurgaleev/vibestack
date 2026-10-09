---
name: guard
description: |
  Full safety mode for prod work: warn before destructive commands and block edits outside one directory.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/guard}/../careful/bin/check-careful.sh"
          statusMessage: "Checking for destructive commands..."
    - matcher: "PowerShell"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/guard}/../careful/bin/check-careful.sh"
          statusMessage: "Checking for destructive commands..."
    - matcher: "Edit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/guard}/../freeze/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
    - matcher: "Write"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/guard}/../freeze/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
    - matcher: "NotebookEdit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/guard}/../freeze/bin/check-freeze.sh"
          statusMessage: "Checking freeze boundary..."
triggers:
  - full safety mode
  - guard against mistakes
  - maximum safety
  - guard mode
  - lock it down
---

## When to invoke

Use when asked to "guard mode", "full safety", "lock it down", or "maximum safety".

# /guard — Full Safety Mode

Activates both destructive command warnings and directory-scoped edit restrictions.
This is `/careful` + `/freeze` in a single command.

**Dependency note:** This skill references hook scripts from the sibling `/careful` and `/freeze` skill directories. Both must be installed (they are installed together by the vibestack install script).

**Where this is enforced.** Both protections run as Claude Code `PreToolUse`
hooks. Cursor, Kiro and Codex install the same skill, but the hooks are not
guaranteed to run there; outside Claude Code `/guard` is instruction-only. On
those hosts, tell the user guard mode is advisory: you will confirm before a
destructive command and keep your own edits inside the boundary, but nothing
blocks a tool call you get wrong.

## Setup

Ask the user which directory to restrict edits to:

> "Guard mode: which directory should edits be restricted to? Destructive command warnings are always on. Files outside the chosen path will be blocked from editing."

Once the user provides a path, set it with the shared state writer (see
`/freeze`):

```bash
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/guard}/../freeze/bin/freeze-state.sh" set "<user-provided-path>"
```

Report guard mode active only if the command exits 0 and prints `FREEZE_DIR=`.
On `FREEZE_ERROR` (a mistyped or missing path, or `/`), tell the user no edit
boundary was set and ask for the path again. On `FREEZE_BUSY`, retry once the
other writer finishes; never write or delete the state file directly.

Tell the user:
- "**Guard mode active.** Two protections are now running:"
- "1. **Destructive command guard** — Bash and PowerShell: rm -rf, Remove-Item -Recurse, DROP TABLE, force-push, etc. warn before executing (you can override); catastrophic shapes (recursive delete of `/` or `~`, force-push to the default branch) are blocked outright"
- "2. **Edit boundary** — Edit, Write and NotebookEdit restricted to `<FREEZE_DIR>/`. Edits outside this directory are blocked."
- "The edit boundary is saved in `~/.vibestack/freeze-dir.txt` and outlives this session: any later session that loads the freeze hook (`/freeze`, `/guard`, `/investigate`) enforces it again. To remove it, run `/unfreeze`. Ending the session turns off the destructive command guard only."

## What's protected

See `/careful` for the two decision tiers, the full pattern list, and the safe exceptions.
See `/freeze` for how edit boundary enforcement works.

Both hooks fail safe when they cannot read a tool payload — `/careful` asks,
`/freeze` denies. Guard mode runs both, so an unreadable Edit, Write or
NotebookEdit payload is blocked, not waved through.
