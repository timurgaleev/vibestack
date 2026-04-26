---
name: commit-push
description: Create git commit and push to remote.
allowed-tools: Read, Bash, Grep, Glob
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

# Commit and Push

## Philosophy

- **Pushes are hard to undo** — be more careful than with commits
- **Affects shared branches** — your changes propagate to the entire team
- **Double-check before pushing** — do a final review after committing, before pushing

## Workflow

### Phase 1: Commit — follow the `/commit` workflow

**Follow the full `/commit` skill workflow:**

1. **Validation** — confirm lint, typecheck, and tests pass
2. **Gather Changes** — review `git status` and `git diff`
3. **Understand Changes** — reflect on changes, ask "why?", assess impact
4. **Security Review** — check for secrets and debug code
5. **Stage & Commit** — stage files and write a conventional commit message
6. **Verify Commit** — confirm commit result

**Commit Message Format:**
```
<type>: <subject>

<optional body explaining why>
```

> **Note:** Commit messages do not use scope. Scope is optionally used in PR titles only.

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `perf`, `ci`

### Phase 2: Pre-Push Deliberation

**CRITICAL: Do not push immediately after committing. Think again first.**

```bash
# Review what will be pushed
git log origin/$(git branch --show-current)..HEAD --oneline 2>/dev/null || git log --oneline -3

# Verify branch
git branch --show-current
```

**Push deliberation checklist:**
- [ ] Correct branch? (confirm push to main/master is intentional)
- [ ] All commits are intentional? (no accidentally included commits)
- [ ] No force push needed? (force push only on explicit request)
- [ ] CI/CD will be triggered — are changes ready for that?

### Phase 3: Push

```bash
# Push to remote (set upstream if new branch)
git push -u origin $(git branch --show-current)
```

### Phase 4: Verify

```bash
git status
git log --oneline -3
```

## Pre-Push Safety Rules

| Rule | Reason |
|------|--------|
| No force push to main/master | Shared history destruction |
| No push with failing tests | Breaks CI for entire team |
| No push of secrets | Once pushed, consider compromised |
| Verify target branch | Wrong branch push is hard to undo |

## Rules

- Only include actual work done in the message
- Do NOT add unnecessary lines (Co-Authored-By, Generated with, etc.)
- Do NOT add promotional or attribution footers
- Do NOT force push to main/master branches

## Anti-Patterns

- Do NOT push without understanding what will be pushed
- Do NOT push immediately after commit without reviewing
- Do NOT commit multiple unrelated changes together
- Do NOT use vague messages like "fix", "update", "WIP"
- Do NOT commit secrets or credentials
- Do NOT skip pre-commit hooks (--no-verify)
- Do NOT force push (--force) unless explicitly requested
- Do NOT amend commits already pushed to shared branches

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"commit-push","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
