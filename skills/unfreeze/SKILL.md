---
name: unfreeze
description: |
  Clear the freeze boundary set by /freeze, allowing edits to all directories
  again. Use when you want to widen edit scope without ending the session.
  Use when asked to "unfreeze", "unlock edits", "remove freeze", or
  "allow all edits".
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

# /unfreeze — Clear Freeze Boundary

Remove the edit restriction set by `/freeze`, allowing edits to all directories.

```bash
STATE_DIR="${TSTACKVIBE_HOME:-$HOME/.tstackvibe}"
if [ -f "$STATE_DIR/freeze-dir.txt" ]; then
  PREV=$(cat "$STATE_DIR/freeze-dir.txt")
  rm -f "$STATE_DIR/freeze-dir.txt"
  echo "Freeze boundary cleared (was: $PREV). Edits are now allowed everywhere."
else
  echo "No freeze boundary was set."
fi
```

Tell the user the result. Note that `/freeze` hooks remain registered for the
session — they will allow all paths since no state file exists. To re-freeze,
run `/freeze` again.
