---
name: learn
description: |
  Manage project learnings. Review, search, prune, and export what vibestack
  has learned across sessions. Use when asked to "what have we learned",
  "show learnings", "prune stale learnings", or "export learnings".
  Proactively suggest when the user asks about past patterns or wonders
  "didn't we fix this before?"
triggers:
  - show learnings
  - what have we learned
  - manage project learnings
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Glob
  - Grep
---

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

## Detect command

Parse the user's input to determine which command to run:

- `/learn` (no arguments) → **Show recent**
- `/learn search <query>` → **Search**
- `/learn prune` → **Prune**
- `/learn export` → **Export**
- `/learn stats` → **Stats**
- `/learn add` → **Manual add**

---

## Show recent (default)

Show the most recent 20 learnings, grouped by type.

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
~/.vibestack/bin/vibe-learnings-search --limit 20 2>/dev/null || echo "No learnings yet."
```

Present the output in a readable format. If no learnings exist, tell the user:
"No learnings recorded yet. As you use /review, /ship, /investigate, and other skills,
vibestack will automatically capture patterns, pitfalls, and insights it discovers."

---

## Search

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
~/.vibestack/bin/vibe-learnings-search --query "USER_QUERY" --limit 20 2>/dev/null || echo "No matches."
```

Replace USER_QUERY with the user's search terms. Present results clearly.

---

## Prune

Check learnings for staleness and contradictions.

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
~/.vibestack/bin/vibe-learnings-search --limit 100 2>/dev/null
```

For each learning in the output:

1. **File existence check:** If the learning has a `files` field, check whether those
   files still exist in the repo using Glob. If any referenced files are deleted, flag:
   "STALE: [key] references deleted file [path]"

2. **Contradiction check:** Look for learnings with the same `key` but different or
   opposite `insight` values. Flag: "CONFLICT: [key] has contradicting entries —
   [insight A] vs [insight B]"

Present each flagged entry via AskUserQuestion:
- A) Remove this learning
- B) Keep it
- C) Update it (I'll tell you what to change)

For removals, read the learnings.jsonl file and remove the matching line, then write
back. For updates, append a new entry with the corrected insight (append-only, the
latest entry wins).

---

## Export

Export learnings as markdown suitable for adding to CLAUDE.md or project documentation.

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
~/.vibestack/bin/vibe-learnings-search --limit 50 2>/dev/null
```

Format the output as a markdown section:

```markdown
## Project Learnings

### Patterns
- **[key]**: [insight] (confidence: N/10)

### Pitfalls
- **[key]**: [insight] (confidence: N/10)

### Preferences
- **[key]**: [insight]

### Architecture
- **[key]**: [insight] (confidence: N/10)
```

Present the formatted output to the user. Ask if they want to append it to CLAUDE.md
or save it as a separate file.

---

## Stats

Show summary statistics about the project's learnings.

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
VIBESTACK_HOME="${VIBESTACK_HOME:-$HOME/.vibestack}"
LEARN_FILE="$VIBESTACK_HOME/projects/$SLUG/learnings.jsonl"
if [ -f "$LEARN_FILE" ]; then
  TOTAL=$(wc -l < "$LEARN_FILE" | tr -d ' ')
  echo "TOTAL: $TOTAL entries"
  # Count by type (after dedup)
  python3 - <<'PYEOF'
import json, sys
from collections import Counter
learn_file = "$LEARN_FILE"
try:
    raw = open(learn_file).read().strip().split('
')
except FileNotFoundError:
    print("NO_LEARNINGS"); sys.exit(0)
entries = []
for l in raw:
    try: entries.append(json.loads(l))
    except: pass
seen = {}
for e in entries:
    dk = (e.get('key',''), e.get('type',''))
    if dk not in seen or e.get('ts','') >= seen[dk].get('ts',''):
        seen[dk] = e
uniq = list(seen.values())
by_type = Counter(e.get('type','?') for e in uniq)
by_src  = Counter(e.get('source','?') for e in uniq)
avg_c   = sum(e.get('confidence',0) for e in uniq) / max(len(uniq),1)
print(f"UNIQUE: {len(uniq)} (after dedup)")
print(f"RAW_ENTRIES: {len(entries)}")
print(f"BY_TYPE: {dict(by_type)}")
print(f"BY_SOURCE: {dict(by_src)}")
print(f"AVG_CONFIDENCE: {avg_c:.1f}")
PYEOF
else
  echo "NO_LEARNINGS"
fi
```

Present the stats in a readable table format.

---

## Manual add

The user wants to manually add a learning. Use AskUserQuestion to gather:
1. Type (pattern / pitfall / preference / architecture / tool)
2. A short key (2-5 words, kebab-case)
3. The insight (one sentence)
4. Confidence (1-10)
5. Related files (optional)

Then log it:

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"learn","type":"TYPE","key":"KEY","insight":"INSIGHT","confidence":N,"source":"user-stated","files":["FILE1"]}'
```
