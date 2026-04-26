---
name: pr-create
description: Create pull request with proper format.
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

# Create Pull Request

## Philosophy

- **A PR is the start of code review** — write it so reviewers can understand the context
- **Explain the "why" of the change** — a diff shows "what", but a PR must explain "why"
- **Be honest about impact** — do not hide the risks and limitations of the change

## Workflow

### 0. Run Validation First
Before creating PR, run `/validate` to ensure all checks pass:
- Lint
- Typecheck
- Tests

**If validation fails, fix all issues before proceeding.**
**If the project has no lint/typecheck/test tooling (e.g., shell scripts, dotfiles), skip this step.**

### 1. Gather Context
```bash
# Detect base branch dynamically
BASE_BRANCH=$(gh pr view --json baseRefName -q '.baseRefName' 2>/dev/null || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

# Check current branch status
git status

# View commits since branching from base
git log origin/${BASE_BRANCH}..HEAD --oneline

# View full diff for PR description
git diff origin/${BASE_BRANCH}...HEAD --stat
git diff origin/${BASE_BRANCH}...HEAD
```

### 2. Deep Analysis

**CRITICAL: Do not just read diff stats — understand the meaning of every change.**

**For each changed file, read and understand:**
1. **Purpose** — why was this file changed?
2. **Impact** — what depends on this file? What could break?
3. **Completeness** — are there related changes that should be included?

**Deliberation questions:**
- What is the **single purpose** of this PR?
- Could this be broken into smaller PRs?
- What are the **risks** of merging this?
- What **edge cases** might be affected?
- Is there adequate **test coverage** for the changes?
- Are there any **breaking changes** for consumers?

### 3. Sync with Main (if needed)

**CRITICAL: Only rebase and force push after explicit user confirmation.**

```bash
git fetch origin

# Check if rebase is needed
git log --oneline origin/${BASE_BRANCH}..HEAD
git log --oneline HEAD..origin/${BASE_BRANCH}
```

If the branch is behind `origin/${BASE_BRANCH}`:
1. **Notify the user that a rebase is needed and ask for confirmation**
2. If user approves, run:
   ```bash
   git rebase origin/${BASE_BRANCH}
   # Resolve conflicts if any, then:
   git push --force-with-lease
   ```
3. If user declines, create the PR without rebasing

### 4. Craft PR Description

**Before writing, articulate:**
1. What problem does this PR solve? (Summary)
2. What specific changes were made and why? (Changes)
3. Are there any breaking changes? (Breaking Changes)
4. How should a reviewer verify this works? (Test Plan)
5. What risks or limitations exist? (if any)

```bash
gh pr create --title "<type>(<scope>): <subject>" --body "$(cat <<'EOF'
## Summary
- Brief description of what and WHY

## Changes
- Change 1: why this was needed
- Change 2: why this was needed

## Breaking Changes
- (if any) Description of breaking change and migration path
- (if none, omit this section entirely)

## Test Plan
- [ ] How to verify changes work
- [ ] Edge cases to test
EOF
)"
```

### 5. Verify PR
```bash
gh pr view --web
```

## PR Title Format
```
<type>(<scope>): <subject>
```

> **Note:** PR title optionally uses scope. PRs covering multiple commits can use scope to clarify the impact area for reviewers. Commit messages use `<type>: <subject>` format without scope.

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance

**Examples:**
```
feat(auth): add OAuth2 login support
fix(api): handle null response from server
refactor(utils): simplify date formatting logic
```

## PR Quality Checklist

Before creating:
- [ ] I can explain the purpose of every changed file
- [ ] Changes are focused (one purpose per PR)
- [ ] Test coverage exists for new/changed logic
- [ ] No secrets, debug code, or unintended files
- [ ] PR title accurately describes the change
- [ ] Description explains WHY, not just WHAT

## Rules

- Only include actual work done in the message
- Do NOT add unnecessary lines (Co-Authored-By, Generated with, etc.)
- Do NOT add promotional or attribution footers

## Anti-Patterns

- Do NOT create PR without reading the full diff
- Do NOT write vague descriptions like "various fixes"
- Do NOT include unrelated changes to pad the PR
- Do NOT skip the test plan — reviewers need it
- Do NOT hide risks or known issues from the description

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"pr-create","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
