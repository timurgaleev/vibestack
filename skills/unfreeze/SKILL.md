---
name: unfreeze
description: |
  Clear the freeze boundary set by /freeze, allowing edits to all directories again.
allowed-tools:
  - Bash
  - Read
triggers:
  - unfreeze edits
  - unlock all directories
  - remove edit restrictions
  - allow all edits
  - exit careful mode
---

## When to invoke

Use when you want to widen edit scope. Ending the session does not lift the boundary: it persists in `~/.vibestack/freeze-dir.txt` until this runs. Use when asked to "unfreeze", "unlock edits", "remove freeze", or "allow all edits".

# /unfreeze — Clear Freeze Boundary

Remove the edit restriction set by `/freeze`, allowing edits to all directories.

```bash
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/unfreeze}/../freeze/bin/freeze-state.sh" clear
```

The shared state writer removes the boundary under the same lock `/freeze`,
`/guard` and `/investigate` use. This also clears a boundary `/investigate`
acquired and could not release (a killed session). Tell the user the result.
On `FREEZE_BUSY`, retry once the other writer finishes; never delete the state
file directly. Note that `/freeze` hooks remain registered for the
session — they will allow all paths since no state file exists. To re-freeze,
run `/freeze` again.
