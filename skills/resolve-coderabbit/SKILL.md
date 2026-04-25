---
name: resolve-coderabbit
description: Use when a PR has CodeRabbit review comments that need to be addressed. Fetches, evaluates, fixes, and resolves CodeRabbit feedback.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Task
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

# Resolve CodeRabbit Reviews

Fetch CodeRabbit inline review comments from a PR, technically evaluate each one, fix valid issues, and resolve completed threads.

## Philosophy

- **Do not blindly accept review suggestions** — evaluate each one technically against codebase reality
- **Respect YAGNI** — have the courage to reject abstractions or complexity that aren't needed yet
- **Fix root causes** — if a suggestion points to a symptom, find the real problem underneath

## Rules

- Read files completely before making changes
- Fix root causes, not symptoms
- Make minimal, focused changes
- Test after each fix
- NEVER blindly implement suggestions — verify against codebase reality first
- REJECT suggestions that violate YAGNI, project architecture, or CLAUDE.md conventions
- Do NOT resolve REJECT items — leave for human judgment

## Process

### Step 1: Identify PR

Determine the PR number from argument or current branch:

```bash
# If argument provided, use it directly
PR_NUMBER={argument}

# Otherwise, infer from current branch
gh pr view --json number -q '.number'
```

Also extract owner and repo:

```bash
gh repo view --json owner,name -q '"\(.owner.login) \(.name)"'
```

### Step 2: Fetch CodeRabbit Comments

Fetch all inline review comments and filter for CodeRabbit:

```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  --paginate \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]") | {id: .id, node_id: .node_id, path: .path, line: .line, original_line: .original_line, body: .body, in_reply_to_id: .in_reply_to_id, created_at: .created_at}]'
```

Filter out reply comments (keep only top-level comments where `in_reply_to_id` is null).

If no CodeRabbit comments found, report and stop.

### Step 3: Map Review Threads

Query GraphQL to get review thread IDs and resolution status:

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 1) {
              nodes {
                id
                databaseId
                body
                path
                line
              }
            }
          }
        }
      }
    }
  }
' -f owner='{owner}' -f repo='{repo}' -F pr={pr_number}
```

Build a mapping: `comment databaseId → thread node ID`.

**Exclude already-resolved threads** from further processing.

### Step 4: Technical Evaluation

For each unresolved CodeRabbit comment, evaluate against the codebase:

**Evaluation checklist:**

1. **Read the target file** — check current state (may already be fixed)
2. **Understand the suggestion** — what exactly is being asked?
3. **Check technical validity** — is this correct for THIS codebase?
4. **Check YAGNI** — does the suggestion add unused complexity?
5. **Check architecture alignment** — conflicts with CLAUDE.md or project conventions?
6. **Check scope** — is this within the PR's intent or scope creep?

**Classification:**

| Decision | Criteria | Action |
|----------|----------|--------|
| **SKIP** | Already fixed in current code, or comment is on deleted/moved code | Resolve only |
| **ACCEPT** | Technically valid, improves code quality, aligns with project conventions | Fix then resolve |
| **REJECT** | YAGNI, technically incorrect, conflicts with architecture, reviewer lacks context | Do NOT resolve |

**Severity for ACCEPT items:**

| Severity | Examples |
|----------|----------|
| HIGH | Security issues, bugs, data loss risks |
| MEDIUM | Missing error handling, type safety gaps, logic improvements |
| LOW | Style suggestions, minor readability improvements, naming |

**Present classification table to user before proceeding:**

```
## CodeRabbit Review Analysis

| # | File | Line | Summary | Decision | Severity | Reason |
|---|------|------|---------|----------|----------|--------|
| 1 | src/foo.ts | 42 | Add null check | ACCEPT | HIGH | Valid — unhandled null |
| 2 | src/bar.ts | 15 | Extract interface | REJECT | - | YAGNI — single implementation |
| 3 | src/baz.ts | 8 | Fix typo | SKIP | - | Already fixed |
```

### Step 5: Apply Fixes

For ACCEPT items, fix in severity order (HIGH → MEDIUM → LOW):

```
# Detect package manager first
if [ -f "pnpm-lock.yaml" ]; then PM="pnpm"
elif [ -f "yarn.lock" ]; then PM="yarn"
elif [ -f "bun.lockb" ]; then PM="bun"
else PM="npm"; fi

FOR each ACCEPT item (by severity):
  1. Read the full target file
  2. Understand surrounding context
  3. Make minimal, focused fix
  4. Run typecheck: $PM run typecheck
  5. Run tests: $PM test
  6. If tests fail, fix or rollback
```

**Never batch fixes** — one at a time, verify each.

### Step 6: Resolve Threads

Resolve threads for SKIP and successfully-fixed ACCEPT items:

```bash
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }
' -f threadId='{THREAD_NODE_ID}'
```

**Do NOT resolve REJECT items** — leave for human judgment.

### Step 7: Final Summary

```
## Resolve Summary

### Statistics
- Total CodeRabbit comments: {N}
- Already resolved: {N}
- ACCEPT (fixed & resolved): {N}
- SKIP (resolved): {N}
- REJECT (not resolved): {N}

### ACCEPT — Fixed
| # | File | Change | Status |
|---|------|--------|--------|
| 1 | src/foo.ts:42 | Added null check | Resolved |

### REJECT — Requires Human Review
| # | File | Suggestion | Reason for Rejection |
|---|------|-----------|---------------------|
| 1 | src/bar.ts:15 | Extract interface | YAGNI — only one implementation exists |

### Verification
- Typecheck: PASS
- Tests: PASS
```

## Technical Evaluation Guidelines

Reference: `receiving-code-review` skill principles.

### When to REJECT

- **YAGNI**: Suggestion adds unused abstraction, interface, or feature
  - Grep codebase for actual usage before implementing
- **Architecture conflict**: Violates CLAUDE.md conventions or project patterns
  - e.g., "1 interface per file" when project groups related types
- **Context gap**: Reviewer doesn't understand full picture
  - e.g., Suggesting removal of code that handles edge cases
- **Scope creep**: Beyond PR's intent
  - e.g., Suggesting broad refactoring when PR is a focused bug fix
- **Already handled**: Logic exists elsewhere that reviewer didn't see
- **Premature abstraction**: Suggesting patterns for single-use code
- **Style-only with tradeoffs**: Cosmetic changes that reduce readability in context

### When to ACCEPT

- Security vulnerabilities or bug fixes
- Missing error handling on external boundaries
- Type safety improvements that prevent runtime errors
- Genuine readability improvements aligned with project style
- Performance issues with measurable impact
- Missing validation on user input

### REJECT Response Pattern

Do not resolve. Report to user with technical reasoning:

```
REJECT: {file}:{line} — {summary}
Reason: {technical explanation referencing codebase evidence}
```

## Anti-Patterns

- Do NOT blindly accept all CodeRabbit suggestions
- Do NOT resolve threads without verifying the fix works
- Do NOT batch multiple fixes without testing between each
- Do NOT implement suggestions that conflict with CLAUDE.md
- Do NOT resolve REJECT items — human decides
- Do NOT skip reading files before making changes
- Do NOT add `any` types or `@ts-ignore` to satisfy suggestions

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.tstackvibe/bin/tvibe-learnings-log '{"skill":"resolve-coderabbit","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
