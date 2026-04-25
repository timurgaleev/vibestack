---
name: reroll-buddy
description: Use when the user wants to reroll their Claude Code /buddy companion pet. Triggers on "/reroll-buddy", "reroll buddy", "reset pet", "reset companion", "new buddy".
allowed-tools: Read, Edit, Bash
---

## Preamble

```bash
eval "$(~/.tstackvibe/bin/tvibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${TSTACKVIBE_HOME:-$HOME/.tstackvibe}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.tstackvibe/bin/tvibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

# Reroll Buddy

Skill to reset the Claude Code `/buddy` companion pet so a new one can be picked.

## Overview

The pet information picked via `/buddy` is stored in the `~/.claude.json` file under the `companion` key. Removing this key allows `/buddy` to be run again to pick a new pet.

## Workflow

### 1. Check Current Pet

```bash
python3 -c "
import json, os
path = os.path.expanduser('~/.claude.json')
with open(path, 'r') as f:
    data = json.load(f)
if 'companion' not in data:
    print('NO_COMPANION')
else:
    print(json.dumps(data['companion'], indent=2, ensure_ascii=False))
"
```

- If `companion` key is absent: inform user "Already reset. Run `/buddy` to pick a new pet." and stop.
- If `companion` key exists: show the current pet name and personality to the user.

### 2. User Confirmation

**Always** get confirmation from the user:
- Display the current pet name
- Ask: "Reset this pet and pick a new one?"

### 3. Remove companion Key

If user confirms, remove only the `companion` key:

```bash
python3 -c "
import json, os
path = os.path.expanduser('~/.claude.json')
with open(path, 'r') as f:
    data = json.load(f)
del data['companion']
with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('Done')
"
```

### 4. Guide User

After reset, instruct the user to run `/buddy` again to pick a new pet.

## Important

- `~/.claude.json` is a core Claude Code config file — remove only the `companion` key
- User confirmation is required before removing
- `/buddy` is a time-limited feature; rerolling may not always be available

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.tstackvibe/bin/tvibe-learnings-log '{"skill":"reroll-buddy","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
