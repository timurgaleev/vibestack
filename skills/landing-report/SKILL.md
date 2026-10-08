---
name: landing-report
description: |
  Read-only queue dashboard for workspace-aware ship. Shows which VERSION slots are currently claimed by open PRs against the same base branch, and what slot /ship would pick next. No mutations — just a snapshot.
triggers:
  - landing report
  - version queue
  - ship queue
  - what version comes next
  - show open PR versions
allowed-tools:
  - Bash
  - Read
---

## When to invoke

Use when asked to "landing report", "what's in the queue", "show me open PRs", or "which version do I claim next".

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

{{include lib/snippets/session-host.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## Why this skill exists

When you're running several branches in parallel, it helps to see — at a
glance — which version numbers are claimed, by which PR, and what slot your next
`/ship` would land in. This skill is a read-only call into the same
`~/.vibestack/bin/vibe-next-version` utility `/ship` uses, but with nothing mutating.
Think of it as `gh pr list` for VERSION numbers.

---

## Step 1: Detect platform and base branch

Same detection as other vibestack skills.

```bash
BASE_BRANCH=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || \
              gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || \
              echo main)
echo "Base branch: $BASE_BRANCH"
```

---

## Step 2: Read current state

```bash
CURRENT_VERSION=$(cat VERSION 2>/dev/null | tr -d '[:space:]' || echo "0.0.0.0")
git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true
BASE_VERSION=$(git show "origin/$BASE_BRANCH:VERSION" 2>/dev/null | tr -d '[:space:]' || echo "$CURRENT_VERSION")
echo "origin/$BASE_BRANCH VERSION: $BASE_VERSION"
echo "branch HEAD VERSION: $CURRENT_VERSION"
```

---

## Step 3: Query the queue

Call the util once per bump level so the user sees what they'd claim for
patch/minor/major. Versions are `MAJOR.MINOR.PATCH`; there is no separate micro
level (the util treats `micro` as `patch`).

```bash
for LEVEL in patch minor major; do
  ~/.vibestack/bin/vibe-next-version \
    --base "$BASE_BRANCH" \
    --bump "$LEVEL" \
    --current-version "$BASE_VERSION" \
    > "/tmp/landing-$LEVEL.json" 2>/dev/null || echo '{"offline":true,"reason":"vibe-next-version failed","claimed":[],"warnings":[]}' > "/tmp/landing-$LEVEL.json"
done
```

---

## Step 4: Render the dashboard

Build a single table output. Use the `patch`-level JSON as canonical for the
queue (it is identical across bump levels; only `.version` differs).

`vibe-next-version` emits exactly these fields — render only what they contain:
- `.host` — `github` | `gitlab` | `unknown`
- `.base` — the base branch the queue was filtered to
- `.offline` — `true` when no PR host was reachable
- `.reason` — one-line explanation of the pick (or of the offline fallback)
- `.claimed` — array of `{pr, branch, version, url}`: open PRs against `.base`
  whose head `VERSION` is ahead of the base version. Read from each PR's head
  `VERSION` file, not its title.
- `.warnings` — PRs whose head `VERSION` could not be read or is malformed
- `.version` — the slot `/ship` would claim at this bump level

Sibling worktree detection is not supported: `.active_siblings` is always an
empty list. Do not render a sibling section, and do not infer siblings from
`git worktree list` or anywhere else. A PR number, branch or version that is
not in `.claimed` does not exist — never fill a row in from memory or a guess.

Render in this exact format:

```
╔══════════════════════════════════════════════════════════════════╗
║                   VIBESTACK LANDING REPORT                      ║
╠══════════════════════════════════════════════════════════════════╣
║ Repo:    <owner/repo>                                            ║
║ Base:    <.base> @ v<base-version>                               ║
║ Host:    <.host>                                                 ║
║ Status:  ONLINE                                                  ║
╚══════════════════════════════════════════════════════════════════╝

Open PRs claiming versions on <.base>:
  #<pr>  <branch>             → v<version>
  #<pr>  <branch>             → v<version>  ⚠ collision with #<pr>

Warnings:
  <one line per entry in .warnings; omit the section when empty>

If you ran /ship right now, you'd claim:
  patch bump:  v<patch .version>   (<patch .reason>)
  minor bump:  v<minor .version>   (<minor .reason>)
  major bump:  v<major .version>   (<major .reason>)
```

A collision is two entries in `.claimed` with the same `version`. When
`.claimed` is empty, print `Open PRs claiming versions on <.base>: none`.

For offline output (`.offline` is `true`), print a shorter block:

```
╔══════════════════════════════════════════════════════════════════╗
║                   VIBESTACK LANDING REPORT                      ║
╠══════════════════════════════════════════════════════════════════╣
║ Status:  OFFLINE — queue-awareness unavailable                   ║
║ Reason:  <.reason>                                               ║
╚══════════════════════════════════════════════════════════════════╝

Fallback: local VERSION bumps still work, but collisions cannot be detected.
```

---

## Step 5: Suggest next action

After rendering the table, suggest ONE of:

1. **If there are collisions in the queue** (two open PRs claim the same version):
   "⚠ Two open PRs collide on v<X>. Whoever merges second will either overwrite
   the first's CHANGELOG entry or land a duplicate. Consider asking one author
   to rerun /ship to pick up the next free slot."

2. **If `.warnings` is non-empty:**
   "Some open PRs' VERSION could not be read (listed above), so the queue may be
   incomplete. Check those PRs before trusting the next slot."

3. **If everything looks clean:**
   "Queue is clean. Next /ship will claim a slot without conflict."

---

## Plan Mode

PLAN MODE EXCEPTION — ALWAYS RUN. This skill is entirely read-only: no file
writes, no git mutations, no network state changes. Safe to run in plan mode.
