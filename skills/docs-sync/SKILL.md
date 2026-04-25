---
name: docs-sync
description: Analyze code and documentation, find gaps, update docs.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
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

# Documentation Sync

Analyze entire codebase and documentation, find gaps, update docs.

## Philosophy

- **Docs must reflect the truth of the code** — docs that differ from code are worse than no docs
- **Wrong is more dangerous than missing** — incorrect docs lead developers in the wrong direction
- **Verify actual behavior** — read the code, compare to docs, find the discrepancies

## Rules

- **Skip temporary/generated directories** - apply exclude patterns before scanning
- **Do NOT create new documentation files** unless explicitly requested
- Only `README.md` and `CLAUDE.md` in project root
- All other docs in `docs/` directory
- Single source of truth - no duplicate content
- Update existing docs, don't add new ones

## Exclude Patterns

**Important: Always skip these directories before scanning the codebase.**

These are auto-generated files, not source code - do not document them.

| Category | Directories |
|----------|-------------|
| Dependencies | `node_modules/`, `vendor/`, `bower_components/`, `.pnp/` |
| Build outputs | `dist/`, `build/`, `out/`, `target/`, `.next/`, `.nuxt/`, `.vercel/` |
| Cache | `.cache/`, `.tmp/`, `tmp/`, `__pycache__/`, `.turbo/`, `.parcel-cache/` |
| Virtual envs | `.venv/`, `venv/`, `.env/`, `env/` |
| VCS | `.git/`, `.svn/`, `.hg/` |
| IDE | `.idea/`, `.vscode/`, `.vs/` |
| Test outputs | `coverage/`, `.nyc_output/`, `test-results/` |
| Generated | `*.min.js`, `*.bundle.js`, lock files (`package-lock.json`, etc.) |
| OS | `.DS_Store`, `Thumbs.db` |

## Process

### 1. Analyze Code
- Apply exclude patterns first
- Scan only actual source files (src/, lib/, app/, etc.)
- Extract public APIs, functions, classes
- Find environment variables, CLI flags
- Build code inventory

### 2. Analyze Documentation
- Read README.md, CLAUDE.md, docs/*
- Extract documented items
- Check structure and index
- Build docs inventory

### 3. Verify Accuracy

**CRITICAL: Before looking for missing docs, verify that existing docs are accurate.**

For each documented item:
1. **Find the corresponding code** — does the documented function/API/config actually exist?
2. **Compare behavior** — does the code do what the docs say?
3. **Check parameters** — are function signatures, API parameters, config options accurate?
4. **Verify examples** — do documented examples actually work with current code?

**Ask "Why is this wrong?"** for each mismatch:
- Was the code changed without updating docs?
- Was the doc written based on planned (not actual) behavior?
- Has a dependency changed the behavior?

### 4. Compare & Report
```
## Gap Report

Inaccurate (PRIORITY — fix first):
- README.md says MAX_RETRY=3, code uses MAX_RETRY=5
- API docs show POST /api/users, code expects PUT /api/users

Undocumented:
- function parseConfig() in src/config.ts

Orphaned (remove from docs):
- /api/legacy in docs/API.md (endpoint deleted)
```

### 5. Update
- Fix inaccurate documentation first (highest priority)
- Remove orphaned content
- Add missing documentation
- Do NOT create new files

### 6. Verify
- Examples work
- Links valid
- No duplicates
- Documented behavior matches actual code behavior

## Structure

```
project/
├── README.md         # Overview only
├── CLAUDE.md         # AI instructions only
└── docs/
    ├── README.md     # Index
    └── *.md          # All other docs
```

## Quality

- Clear headings, no skipped levels
- Working code examples
- No duplicate content (link instead)
- Keep docs concise

## Anti-Patterns

- Do NOT assume documentation is correct — verify against code
- Do NOT add documentation for trivial/obvious code
- Do NOT create new doc files unless explicitly requested
- Do NOT document implementation details that change frequently
- Do NOT copy code into documentation — reference it

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.tstackvibe/bin/tvibe-learnings-log '{"skill":"docs-sync","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
