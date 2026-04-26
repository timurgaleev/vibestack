---
name: commit
description: Create git commit with conventional format.
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

# Create Commit

## Philosophy

- **Understand changes before committing** — grasp the purpose and impact, not just the diff
- **Commit messages answer "why"** — explain why the change was made, not what was changed
- **One commit, one purpose** — separate unrelated changes into distinct commits

## Workflow

### 0. Run Validation First
Before committing, run `/validate` to ensure all checks pass:
- Lint
- Typecheck
- Tests

**If validation fails, fix all issues before proceeding.**
**If the project has no lint/typecheck/test tooling (e.g., shell scripts, dotfiles), skip this step.**

### 1. Gather Changes
```bash
# Check current status (never use -uall flag)
git status

# View staged and unstaged changes
git diff
git diff --cached

# View recent commits for message style reference
git log --oneline -10
```

### 2. Understand Changes

**CRITICAL: Do not just read the diff — understand the meaning of the change.**

For each changed file:
1. **Read the changed file** — understand the full context, not just the diff
2. **Ask "Why?"** — why was this change needed? What problem does it solve?
3. **Assess impact** — what other code depends on this? Could this break anything?
4. **Verify correctness** — is the change actually correct? Are edge cases handled?

**Deliberation checklist:**
- [ ] I understand WHY each change was made
- [ ] Changes are logically related (single purpose)
- [ ] No unintended side effects
- [ ] The change addresses the root cause, not a symptom

### 3. Security Review
Before staging:
- [ ] No secrets (API keys, passwords, tokens)
- [ ] No debug code (console.log, print statements)
- [ ] No unintended files (.env, node_modules, etc.)
- [ ] No sensitive data in error messages or comments

### 4. Stage Files
```bash
# Stage specific files (preferred)
git add path/to/file1 path/to/file2

# Or stage all changes (use with caution)
git add -A
```

**Avoid staging:**
- `.env`, `credentials.json`, secrets
- Large binaries or generated files
- Unrelated changes

### 5. Craft Commit Message

**Before writing the message, articulate:**
1. What type of change is this? (feat/fix/refactor/...)
2. What is the core purpose in one sentence?
3. Why was this change necessary? (for the body)

```bash
git commit -m "$(cat <<'EOF'
<type>: <subject>

<optional body explaining why>
EOF
)"
```

### 6. Verify Commit
```bash
git status
git log --oneline -3
```

## Commit Message Format

```
<type>: <subject>

<optional body>
```

> **Note:** Commit messages do not use scope. Scope is optionally used in PR titles only.
> A commit is an atomic unit — type and subject are sufficient to convey intent.

**Types:**
| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code refactoring (no behavior change) |
| `test` | Adding or updating tests |
| `chore` | Maintenance, dependencies |
| `perf` | Performance improvement |
| `ci` | CI/CD changes |

**Subject Rules:**
- Use imperative mood: "Add feature" not "Added feature"
- No period at the end
- Max 50 characters
- Focus on "what" and "why", not "how"

**Examples:**
```
feat: add user authentication with OAuth2
fix: handle null response from payment API
refactor: simplify date formatting logic
docs: update API documentation for v2 endpoints
test: add unit tests for user service
chore: update dependencies to latest versions
```

## Rules

- Only include actual work done in the message
- Do NOT add unnecessary lines (Co-Authored-By, Generated with, etc.)
- Do NOT add promotional or attribution footers

## Anti-Patterns

- Do NOT commit without understanding what changed and why
- Do NOT commit multiple unrelated changes together
- Do NOT use vague messages like "fix", "update", "WIP"
- Do NOT commit secrets or credentials
- Do NOT skip pre-commit hooks (--no-verify)
- Do NOT amend commits already pushed to shared branches

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"commit","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
