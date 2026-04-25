---
name: context-load
description: Load saved project context from ./context.md.
allowed-tools: Read, Bash, Glob
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

# Context Load

Load saved project context to quickly understand the project.

## Workflow

### 1. Check Context File Exists
```bash
ls -la ./context.md 2>/dev/null
```

If not found:
- Inform user: "No context file found. Run `/context-init` first."
- Stop execution

### 2. Check Context Freshness
```bash
# Get last modified date
stat -f "%Sm" ./context.md 2>/dev/null || stat -c "%y" ./context.md 2>/dev/null
```

If older than 7 days, warn user:
```
Context is more than 7 days old. Consider refreshing with `/context-init`.
```

### 3. Load Context
Read the entire `./context.md` file.

### 4. Verify Recent Changes
```bash
# Check for recent changes that might not be in context
git log --oneline -5 --since="$(stat -f '%Sm' -t '%Y-%m-%d' ./context.md 2>/dev/null || date -d "$(stat -c '%y' ./context.md)" '+%Y-%m-%d')" 2>/dev/null
```

If there are commits after context was created, note:
```
There are N commits since this context was created.
Recent changes may not be reflected.
```

### 5. Report Summary

```
## Context Loaded ✅

**Project**: [Project Name]
**Last Updated**: YYYY-MM-DD
**Tech Stack**: [Languages/Frameworks]

### Quick Reference
- Build: `npm run build`
- Test: `npm test`
- Dev: `npm run dev`

Context loaded. Ask anything about the project.
```

## What Context Provides

After loading, you will know:

| Information | Description |
|-------------|-------------|
| **Project Overview** | What the project does |
| **Tech Stack** | Languages, frameworks, dependencies |
| **Directory Structure** | Where to find what |
| **Key Files** | Important entry points and modules |
| **Commands** | How to build, test, run |
| **Architecture** | How components interact |
| **Conventions** | Coding style and patterns |

## Limitations

Context load provides a **snapshot** of the project:

| Limitation | Workaround |
|------------|------------|
| Static snapshot | Run `/context-init` to refresh |
| Summary, not full code | Read specific files when needed |
| May be outdated | Check git log for recent changes |

## When to Refresh Context

Run `/context-init` again when:
- Major refactoring occurred
- New features added
- Dependencies changed significantly
- Architecture changed
- Context is older than 1 week

## Rules

- Always check if context file exists first
- Warn if context is stale
- Note any recent commits not in context
- Provide quick reference commands
- Be ready to read additional files if needed

## Anti-Patterns

- Do NOT assume context is always up-to-date — always verify against actual code
- Do NOT rely only on context for critical decisions — read the real files
- Do NOT skip reading actual code when making changes
- Do NOT trust documented commands without verifying they still work

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.tstackvibe/bin/tvibe-learnings-log '{"skill":"context-load","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
