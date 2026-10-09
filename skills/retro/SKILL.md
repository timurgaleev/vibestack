---
name: retro
description: |
  Weekly engineering retrospective from git history: shipping metrics, work patterns, trends and per-person feedback.
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - AskUserQuestion
triggers:
  - weekly retro
  - what did we ship
  - engineering retrospective
---

## When to invoke

Use when asked to "weekly retro", "what did we ship", or "engineering retrospective".

Proactively suggest at the end of a work week or sprint.

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## Step 0: Detect platform and base branch

First, detect the git hosting platform from the remote URL:

```bash
git remote get-url origin 2>/dev/null
```

- If the URL contains "github.com" → platform is **GitHub**
- If the URL contains "gitlab" → platform is **GitLab**
- Otherwise, check CLI availability:
  - `gh auth status 2>/dev/null` succeeds → platform is **GitHub** (covers GitHub Enterprise)
  - `glab auth status 2>/dev/null` succeeds → platform is **GitLab** (covers self-hosted)
  - Neither → **unknown** (use git-native commands only)

Determine which branch this PR/MR targets, or the repo's default branch if no
PR/MR exists. Use the result as "the base branch" in all subsequent steps.

**If GitHub:**
1. `gh pr view --json baseRefName -q .baseRefName` — if succeeds, use it
2. `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` — if succeeds, use it

**If GitLab:**
1. `glab mr view -F json 2>/dev/null` and extract the `target_branch` field — if succeeds, use it
2. `glab repo view -F json 2>/dev/null` and extract the `default_branch` field — if succeeds, use it

**Git-native fallback (if unknown platform, or CLI commands fail):**
1. `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'`
2. If that fails: `git rev-parse --verify origin/main 2>/dev/null` → use `main`
3. If that fails: `git rev-parse --verify origin/master 2>/dev/null` → use `master`

If all fail, fall back to `main`.

Print the detected base branch name. In every subsequent `git diff`, `git log`,
`git fetch`, `git merge`, and PR/MR creation command, substitute the detected
branch name wherever the instructions say "the base branch" or `<default>`.

---

# /retro — Weekly Engineering Retrospective

Generates a comprehensive engineering retrospective analyzing commit history, work patterns, and code quality metrics. Team-aware: identifies the user running the command, then analyzes every contributor with per-person praise and growth opportunities. Designed for a senior IC/CTO-level builder using Claude Code as a force multiplier.

## User-invocable
When the user types `/retro`, run this skill.

## Arguments
- `/retro` — default: last 7 days
- `/retro 24h` — last 24 hours
- `/retro 14d` — last 14 days
- `/retro 30d` — last 30 days
- `/retro compare` — compare current window vs prior same-length window
- `/retro compare 14d` — compare with explicit window



## Instructions

Parse the argument to determine the time window. Default to 7 days if no argument given. All times should be reported in the user's **local timezone** (use the system default — do NOT set `TZ`).

**Midnight-aligned windows:** For day (`d`) and week (`w`) units, compute an absolute start date at local midnight, not a relative string. For example, if today is 2026-03-18 and the window is 7 days: the start date is 2026-03-11. Use `--since="2026-03-11T00:00:00"` for git log queries — the explicit `T00:00:00` suffix ensures git starts from midnight. Without it, git uses the current wall-clock time (e.g., `--since="2026-03-11"` at 11pm means 11pm, not midnight). For week units, multiply by 7 to get days (e.g., `2w` = 14 days back). For hour (`h`) units, use `--since="N hours ago"` since midnight alignment does not apply to sub-day windows.

**Argument validation:** If the argument doesn't match a number followed by `d`, `h`, or `w`, or the word `compare` (optionally followed by a window), show this usage and stop:
```
Usage: /retro [window | compare]
  /retro              — last 7 days (default)
  /retro 24h          — last 24 hours
  /retro 14d          — last 14 days
  /retro 30d          — last 30 days
  /retro compare      — compare this period vs prior period
  /retro compare 14d  — compare with explicit window
```

{{include lib/snippets/prior-learnings.md}}
### Non-git context (optional)

Check for non-git context that should be included in the retro:

```bash
echo "STATE_ROOT: ${VIBESTACK_HOME:-$HOME/.vibestack}"
[ -f "${VIBESTACK_HOME:-$HOME/.vibestack}/retro-context.md" ] && echo "RETRO_CONTEXT_FOUND" || echo "NO_RETRO_CONTEXT"
```

If `RETRO_CONTEXT_FOUND`: read `<STATE_ROOT>/retro-context.md`, where `<STATE_ROOT>` is the path the block printed on its `STATE_ROOT:` line (every `<STATE_ROOT>` below means the same path). This file is user-authored and may contain meeting notes, calendar events, decisions, and other context that doesn't appear in git history. Incorporate this context into the retro narrative where relevant.

### Step 0.5: Stale-base + bad-today-anchor pre-flight guard

The retro skill computes a window from "today" and queries `git log --since=<window> origin/<default>`. If "today" drifts (model session-context error) or the local worktree's `origin/<default>` is materially behind the actual remote, the window can return zero or near-zero commits and the retro will fabricate a coherent-looking narrative from nothing. This guard prevents silent confidently-wrong output.

Run the pre-flight in this exact order. The first branch that matches wins:

```bash
# Pre-check A: no remote configured?
_RETRO_HAS_REMOTE=$(git remote 2>/dev/null | grep -c '^origin$' || echo 0)
if [ "$_RETRO_HAS_REMOTE" = "0" ]; then
  echo "RETRO_GUARD: no 'origin' remote, base freshness not verified — proceeding"
  _RETRO_GUARD_VERDICT="skip-no-remote"
fi

# Pre-check B: detached HEAD or no current base?
if [ -z "$_RETRO_GUARD_VERDICT" ]; then
  _RETRO_HEAD_REF=$(git symbolic-ref --quiet HEAD 2>/dev/null || echo "")
  if [ -z "$_RETRO_HEAD_REF" ]; then
    echo "RETRO_GUARD: detached HEAD, base freshness not verified — proceeding"
    _RETRO_GUARD_VERDICT="skip-detached"
  fi
fi

# Pre-check C: fetch origin <default>; if it fails, warn but proceed.
if [ -z "$_RETRO_GUARD_VERDICT" ]; then
  if ! git fetch origin <default> --quiet 2>/dev/null; then
    echo "RETRO_GUARD: 'git fetch origin <default>' failed (offline?) — proceeding against last-known origin/<default>"
    _RETRO_GUARD_VERDICT="warn-fetch-failed"
  fi
fi

# Pre-check D: BLOCK only when fetch succeeded AND the latest origin/<default>
# commit predates the retro window. Today's date should be loaded from the
# user-visible "## currentDate" tag in the session reminder; if the gap between
# origin/<default>'s newest commit and today exceeds the window, the model's
# "today" is almost certainly stale (or the worktree is wildly behind).
if [ -z "$_RETRO_GUARD_VERDICT" ]; then
  _RETRO_LATEST_ISO=$(git log -1 --format=%ci origin/<default> 2>/dev/null | awk '{print $1}')
  if [ -n "$_RETRO_LATEST_ISO" ]; then
    # The model computes today from the session reminder (NEVER from `date` —
    # the system clock can be hours off in containerized harnesses).
    # Compute window in DAYS (default 7): if today - latest-commit-date > window-days,
    # BLOCK. If the model cannot reliably compute "today", it MUST stop here and
    # ask the user via AskUserQuestion rather than proceeding.
    echo "RETRO_GUARD: latest origin/<default> commit on $_RETRO_LATEST_ISO"
    _RETRO_GUARD_VERDICT="check-gap"
  fi
fi
```

After running the bash block, the model evaluates `RETRO_GUARD: latest origin/<default> commit on <DATE>` against today and the window:

- If the **latest-commit date is older than (today − window-days)**, BLOCK with: "Retro window is stale. Latest commit on `origin/<default>` was `<DATE>`, but the window covers `<since>` to `<today>`. This usually means either (a) today's date is wrong in this session or (b) `origin/<default>` is materially behind the remote. Confirm today's date via the session reminder; if today is correct, run `git fetch origin <default>` manually and re-run /retro." Stop the skill until the user resolves.
- Otherwise, write: "RETRO_GUARD: latest commit `<DATE>` within window — proceeding."

Skip paths (`skip-no-remote`, `skip-detached`, `warn-fetch-failed`) all proceed to Step 1 with the cited reason on a single stderr line so the retro narrative carries the disclosure ("offline run, window not freshness-verified") rather than silently misreporting.

### Step 1: Gather Raw Data

First, fetch origin, resolve the ref every later query reads, and identify the
current user:
```bash
git fetch origin <default> --quiet 2>/dev/null || true
# Resolve the ref to analyze. Step 0.5 deliberately proceeds when there is no
# origin remote or HEAD is detached — without a fallback those runs would query
# a ref that does not resolve and report zero of everything.
if git rev-parse --verify --quiet "origin/<default>" >/dev/null 2>&1; then
  RETRO_REF="origin/<default>"
elif git rev-parse --verify --quiet "<default>" >/dev/null 2>&1; then
  RETRO_REF="<default>"
else
  RETRO_REF="HEAD"
fi
echo "RETRO_REF=$RETRO_REF"
# Identify who is running the retro
git config user.name
git config user.email
```

Substitute `$RETRO_REF` wherever a command below (and in Steps 11-13) is written
against `origin/<default>`. If `RETRO_REF` is anything other than
`origin/<default>`, the retro analyzed local history — say so on its own line in
the narrative header ("analyzed `<ref>`: no `origin/<default>` in this
worktree"), next to any Step 0.5 skip reason.

The name returned by `git config user.name` is **"you"** — the person reading this retro. All other authors are teammates. Use this to orient the narrative: "your" commits vs teammate contributions.

Run ALL of these git commands in parallel (they are independent):

```bash
# 1. All commits in window with timestamps, subject, hash, AUTHOR, files changed, insertions, deletions
git log origin/<default> --since="<window>" --format="%H|%aN|%ae|%ai|%s" --shortstat

# 2. Per-commit test vs total LOC breakdown with author
#    Each commit block starts with COMMIT:<hash>|<author>, followed by numstat lines.
#    Test files: paths matching '(^|/)(tests?|specs?|__tests__)/|\.(test|spec)\.|_(test|spec)\.|(^|/)test_[^/]*\.py$|_test\.rb$|Tests?\.swift$|\.tftest\.hcl$|\.bats$'.
#    Generated/build paths matching '(^|/)(build|dist|out|target|vendor|node_modules|DerivedData|[.]next|coverage)/'
#    count toward neither test LOC nor logical SLOC, and are dropped from hotspots
#    (commands 4, 10, 13 and 14 apply the same exclusion).
git log origin/<default> --since="<window>" --format="COMMIT:%H|%aN" --numstat

# 3. Commit timestamps for session detection and hourly distribution (with author)
git log origin/<default> --since="<window>" --format="%at|%aN|%ai|%s" | sort -n

# 4. Files most frequently changed (hotspot analysis)
git log origin/<default> --since="<window>" --format="" --name-only | grep -v '^$' \
  | grep -vE '(^|/)(build|dist|out|target|vendor|node_modules|DerivedData|[.]next|coverage)/' | sort | uniq -c | sort -rn

# 5. PR/MR numbers from commit messages (GitHub #NNN, GitLab !NNN)
git log origin/<default> --since="<window>" --format="%s" | grep -oE '[#!][0-9]+' | sort -t'#' -k1 | uniq

# 6. Per-author file hotspots (who touches what)
git log origin/<default> --since="<window>" --format="AUTHOR:%aN" --name-only

# 7. Per-author commit counts (quick summary)
git shortlog origin/<default> --since="<window>" -sn --no-merges

# 8. Greptile triage history (if available)
cat "${VIBESTACK_HOME:-$HOME/.vibestack}/greptile-history.md" 2>/dev/null || true

# 9. TODOS.md backlog (if available)
cat TODOS.md 2>/dev/null || true

# 10. Test file count
find . -type f -not -path './.git/*' 2>/dev/null \
  | grep -vE '(^|/)(build|dist|out|target|vendor|node_modules|DerivedData|[.]next|coverage)/' \
  | grep -E '(^|/)(tests?|specs?|__tests__)/|\.(test|spec)\.|_(test|spec)\.|(^|/)test_[^/]*\.py$|_test\.rb$|Tests?\.swift$|\.tftest\.hcl$|\.bats$' | wc -l

# 11. Regression test commits in window
git log origin/<default> --since="<window>" --oneline --grep="test(qa):" --grep="test(design):" --grep="test: coverage"

# 12. vibestack skill usage telemetry (if available)
cat "${VIBESTACK_HOME:-$HOME/.vibestack}/analytics/skill-usage.jsonl" 2>/dev/null || true

# 13. Test files changed in window
git log origin/<default> --since="<window>" --format="" --name-only | grep -v '^$' \
  | grep -vE '(^|/)(build|dist|out|target|vendor|node_modules|DerivedData|[.]next|coverage)/' \
  | grep -E '(^|/)(tests?|specs?|__tests__)/|\.(test|spec)\.|_(test|spec)\.|(^|/)test_[^/]*\.py$|_test\.rb$|Tests?\.swift$|\.tftest\.hcl$|\.bats$' | sort -u | wc -l

# 14. Logical SLOC added: added lines minus blanks and comment-only lines.
#     Leader matching is a heuristic, not a parser — good enough to keep the
#     headline number from counting whitespace and license headers as shipping.
#     The awk drops hunks of generated/build files (same pattern as command 4).
git log origin/<default> --since="<window>" --no-merges -p --unified=0 --no-color \
  | awk -v gen='(^|/)(build|dist|out|target|vendor|node_modules|DerivedData|[.]next|coverage)/' '/^\+\+\+ /{skip = (substr($0, 5) ~ gen); next} /^\+/ && !skip' \
  | cut -c2- \
  | grep -vE '^[[:space:]]*$' \
  | grep -vE '^[[:space:]]*(#|//|/\*|\*|--|<!--)' | wc -l

# 15. VERSION file at both ends of the window (skip both lines if no VERSION file)
_FIRST=$(git log origin/<default> --since="<window>" --format=%H | tail -1)
git show "${_FIRST}^:VERSION" 2>/dev/null || git show "${_FIRST}:VERSION" 2>/dev/null
git show origin/<default>:VERSION 2>/dev/null

# 16. Merged PRs/MRs in window (hosting data), from the platform Step 0
#     detected — replace <PLATFORM> with github, gitlab or unknown. The window
#     is bounded at both ends: <start-date> is its first day and <end-date> its
#     last (today for a normal run). glab has no merged-date filter, so the
#     window is applied to merged_at here; each MR prints as
#     "!<iid> <merged_at> <title>".
RETRO_PLATFORM='<PLATFORM>'
case "$RETRO_PLATFORM" in
  github)
    gh pr list --state merged --base <default> --search "merged:<start-date>..<end-date>" --json number,title,mergedAt --limit 200 2>/dev/null || echo PRS_UNAVAILABLE ;;
  gitlab)
    glab mr list --merged --target-branch <default> --per-page 100 -F json 2>/dev/null \
      | python3 -I -c 'import json, sys
start, end = sys.argv[1], sys.argv[2]
for m in json.load(sys.stdin):
    day = (m.get("merged_at") or "")[:10]
    if day and start <= day <= end:
        print("!%s %s %s" % (m["iid"], m["merged_at"], m["title"]))' '<start-date>' '<end-date>' 2>/dev/null \
      || echo PRS_UNAVAILABLE ;;
  *) echo PRS_UNAVAILABLE ;;
esac

# 17. CHANGELOG entries added in window
git log origin/<default> --since="<window>" --format= -p -- CHANGELOG.md | grep '^+' | grep -v '^+++' || true
```

### Step 2: Compute Metrics

Calculate and present these metrics in a summary table:

| Metric | Value |
|--------|-------|
| **Features shipped** (deduplicated CHANGELOG entry lines + merged PR titles) | N |
| Commits to main | N |
| Weighted commits (commits × avg files-touched, capped at 20 per commit) | N |
| Contributors | N |
| PRs merged | N |
| PRs referenced (`#NNN`/`!NNN` in subjects) | N |
| **Logical SLOC added** (non-blank, non-comment — primary code-volume metric) | N |
| Raw LOC: insertions | N |
| Raw LOC: deletions | N |
| Raw LOC: net | N |
| Test LOC (insertions) | N |
| Test LOC ratio | N% |
| Version range | vX.Y.Z.W → vX.Y.Z.W |
| Active days | N |
| Detected sessions | N |
| Avg raw LOC/session-hour | N |
| Greptile signal | N% (Y catches, Z FPs) |
| Test Health | N test files · M test files changed this period · K regression tests |

**Metric order rationale (V1):** features shipped leads — what users got. Commits
and weighted commits reflect intent-to-ship. Logical SLOC added reflects real
new functionality. Raw LOC is demoted to context because AI inflates it; ten
lines of a good fix is not less shipping than ten thousand lines of scaffold.
See docs/designs/PLAN_TUNING_V1.md §Workstream C.

Logical SLOC comes from command 14, version range from command 15. PRs merged
comes from command 16; on `PRS_UNAVAILABLE` the row reads "unavailable (no gh/glab)" —
never infer it from `#NNN` in subjects, which is what PRs referenced (command 5)
counts. Features shipped is the deduplicated CHANGELOG entry lines from command 17
plus the merged PR titles from command 16; when both sources are empty or
unavailable it reads "unavailable", not 0. **Every row traces to a Step 1 command.** If a row has no data source in this repo — no
VERSION file, no CHANGELOG, no Greptile history — drop the row. Never fill a
cell from your own estimate: an estimated number sitting in a table of measured
ones is indistinguishable from a measurement.

Then show a **per-author leaderboard** immediately below:

```
Contributor         Commits   +/-          Top area
You (timur)              32   +2400/-300   browse/
alice                    12   +800/-150    app/services/
bob                       3   +120/-40     tests/
```

Sort by commits descending. The current user (from `git config user.name`) always appears first, labeled "You (name)".

**Greptile signal (if history exists):** Read `<STATE_ROOT>/greptile-history.md` (fetched in Step 1, command 8). Filter entries within the retro time window by date. Count entries by type: `fix`, `fp`, `already-fixed`. Compute signal ratio: `(fix + already-fixed) / (fix + already-fixed + fp)`. If no entries exist in the window or the file doesn't exist, skip the Greptile metric row. Skip unparseable lines silently.

**Backlog Health (if TODOS.md exists):** Read `TODOS.md` (fetched in Step 1, command 9). Compute:
- Total open TODOs (exclude items in `## Completed` section)
- P0/P1 count (critical/urgent items)
- P2 count (important items)
- Items completed this period (items in Completed section with dates within the retro window)
- Items added this period (cross-reference git log for commits that modified TODOS.md within the window)

Include in the metrics table:
```
| Backlog Health | N open (X P0/P1, Y P2) · Z completed this period |
```

If TODOS.md doesn't exist, skip the Backlog Health row.

**Skill Usage (if analytics exist):** Read `<STATE_ROOT>/analytics/skill-usage.jsonl` if it exists. Filter entries within the retro time window by `ts` field. Separate skill activations (no `event` field) from hook fires (`event: "hook_fire"`). Aggregate by skill name. Present as:

```
| Skill Usage | /ship(12) /qa(8) /review(5) · 3 safety hook fires |
```

If the JSONL file doesn't exist or has no entries in the window, skip the Skill Usage row.

**Eureka Moments (if logged):** Read `<STATE_ROOT>/analytics/eureka.jsonl` if it exists. Filter entries within the retro time window by `ts` field. For each eureka moment, show the skill that flagged it, the branch, and a one-line summary of the insight. Present as:

```
| Eureka Moments | 2 this period |
```

If moments exist, list them:
```
  EUREKA /office-hours (branch: timur/auth-rethink): "Session tokens don't need server storage — browser crypto API makes client-side JWT validation viable"
  EUREKA /plan-eng-review (branch: timur/cache-layer): "Redis isn't needed here — Bun's built-in LRU cache handles this workload"
```

If the JSONL file doesn't exist or has no entries in the window, skip the Eureka Moments row.

### Step 3: Commit Time Distribution

Show hourly histogram in local time using bar chart:

```
Hour  Commits  ████████████████
 00:    4      ████
 07:    5      █████
 ...
```

Identify and call out:
- Peak hours
- Dead zones
- Whether pattern is bimodal (morning/evening) or continuous
- Late-night coding clusters (after 10pm)

### Step 4: Work Session Detection

Detect sessions using **45-minute gap** threshold between consecutive commits. For each session report:
- Start/end time (local timezone)
- Number of commits
- Duration in minutes

Classify sessions:
- **Deep sessions** (50+ min)
- **Medium sessions** (20-50 min)
- **Micro sessions** (<20 min, typically single-commit fire-and-forget)

Calculate:
- Total active coding time (sum of session durations)
- Average session length
- LOC per hour of active time

### Step 5: Commit Type Breakdown

Categorize by conventional commit prefix (feat/fix/refactor/test/chore/docs). Show as percentage bar:

```
feat:     20  (40%)  ████████████████████
fix:      27  (54%)  ███████████████████████████
refactor:  2  ( 4%)  ██
```

Flag if fix ratio exceeds 50% — this signals a "ship fast, fix fast" pattern that may indicate review gaps.

### Step 6: Hotspot Analysis

Show top 10 most-changed files. Flag:
- Files changed 5+ times (churn hotspots)
- Test files vs production files in the hotspot list
- VERSION/CHANGELOG frequency (version discipline indicator)

### Step 7: PR Size Distribution

From commit diffs, estimate PR sizes and bucket them:
- **Small** (<100 LOC)
- **Medium** (100-500 LOC)
- **Large** (500-1500 LOC)
- **XL** (1500+ LOC)

### Step 8: Focus Score + Ship of the Week

**Focus score:** Calculate the percentage of commits touching the single most-changed top-level directory (e.g., `app/services/`, `app/views/`). Higher score = deeper focused work. Lower score = scattered context-switching. Report as: "Focus score: 62% (app/services/)"

**Ship of the week:** Auto-identify the single highest-LOC PR in the window. Highlight it:
- PR number and title
- LOC changed
- Why it matters (infer from commit messages and files touched)

### Step 9: Team Member Analysis

For each contributor (including the current user), compute:

1. **Commits and LOC** — total commits, insertions, deletions, net LOC
2. **Areas of focus** — which directories/files they touched most (top 3)
3. **Commit type mix** — their personal feat/fix/refactor/test breakdown
4. **Session patterns** — when they code (their peak hours), session count
5. **Test discipline** — their personal test LOC ratio
6. **Biggest ship** — their single highest-impact commit or PR in the window

**For the current user ("You"):** This section gets the deepest treatment. Include all the detail from the solo retro — session analysis, time patterns, focus score. Frame it in first person: "Your peak hours...", "Your biggest ship..."

**For each teammate:** Write 2-3 sentences covering what they worked on and their pattern. Then:

- **Praise** (1-2 specific things): Anchor in actual commits. Not "great work" — say exactly what was good. Examples: "Shipped the entire auth middleware rewrite in 3 focused sessions with 45% test coverage", "Every PR under 200 LOC — disciplined decomposition."
- **Opportunity for growth** (1 specific thing): Frame as a leveling-up suggestion, not criticism. Anchor in actual data. Examples: "Test ratio was 12% this week — adding test coverage to the payment module before it gets more complex would pay off", "5 fix commits on the same file suggest the original PR could have used a review pass."

**If only one contributor (solo repo):** Skip the team breakdown and proceed as before — the retro is personal.

**If there are Co-Authored-By trailers:** Parse `Co-Authored-By:` lines in commit messages. Credit those authors for the commit alongside the primary author. Note AI co-authors (e.g., `noreply@anthropic.com`) but do not include them as team members — instead, track "AI-assisted commits" as a separate metric.

### Step 10: Week-over-Week Trends (if window >= 14d)

If the time window is 14 days or more, split into weekly buckets and show trends:
- Commits per week (total and per-author)
- LOC per week
- Test ratio per week
- Fix ratio per week
- Session count per week

### Step 11: Streak Tracking

Count consecutive days with at least 1 commit to origin/<default>. Track both team streak and personal streak:

```bash
# Team streak: all unique commit dates (local time) — no hard cutoff
git log origin/<default> --format="%ad" --date=format:"%Y-%m-%d" | sort -u

# Personal streak: only the current user's commits
git log origin/<default> --author="<user_name>" --format="%ad" --date=format:"%Y-%m-%d" | sort -u
```

Each list is anchored at its own **newest commit date**, not at today — Step 0.5
exists because the session's "today" can be wrong, and a streak counted down from
a drifted clock is a fabricated number. Walk back from the newest date in the
list: how many consecutive days have at least one commit? This queries the full
history, so streaks of any length are reported accurately.

Then judge whether the streak is still live:

- Anchor is today or yesterday → the streak is live. "Team shipping streak: 47 consecutive days" / "Your shipping streak: 32 consecutive days"
- Anchor is older → the streak is broken. Report 0 and name the last shipping day: "Team shipping streak: 0 days (last shipped 2026-03-02, 9 days ago)"
- No commits at all in the list → skip the line rather than report 0.

### Step 12: Load History & Compare

Before saving the new snapshot, check for prior retro history:

```bash
setopt +o nomatch 2>/dev/null || true  # zsh compat
ls -t .context/retros/*.json 2>/dev/null
```

**Only compare against a prior retro with the same `window` value** (e.g., 7d vs 7d). Pick the most recent prior retro; if its `window` differs from the current one, skip the Trends section and note: "Prior retro used a different window — skipping comparison."

**If a matching prior retro exists:** Load it using the Read tool. Calculate deltas for key metrics and include a **Trends vs Last Retro** section:
```
                    Last        Now         Delta
Test ratio:         22%    →    41%         ↑19pp
Sessions:           10     →    14          ↑4
LOC/hour:           200    →    350         ↑75%
Fix ratio:          54%    →    30%         ↓24pp (improving)
Commits:            32     →    47          ↑47%
Deep sessions:      3      →    5           ↑2
```

**If no prior retros exist:** Skip the comparison section and append: "First retro recorded — run again next week to see trends."

### Step 13: Save Retro History

After computing all metrics (including streak) and loading any prior history for comparison, save a JSON snapshot:

```bash
mkdir -p .context/retros
```

Determine the next unused sequence number for today. Replace `<TODAY>` with the
`YYYY-MM-DD` date you computed from the session reminder (never from `date`):
```bash
today='<TODAY>'
# First unused number, so a deleted -1 never makes this run overwrite -2
next=1; while [ -e ".context/retros/${today}-${next}.json" ]; do next=$((next+1)); done
echo "SAVE_AS: .context/retros/${today}-${next}.json"
```

Use the Write tool to save the JSON file with this schema:
```json
{
  "date": "2026-03-08",
  "window": "7d",
  "metrics": {
    "commits": 47,
    "contributors": 3,
    "prs_merged": 12,
    "insertions": 3200,
    "deletions": 800,
    "net_loc": 2400,
    "test_loc": 1300,
    "test_ratio": 0.41,
    "active_days": 6,
    "sessions": 14,
    "deep_sessions": 5,
    "avg_session_minutes": 42,
    "loc_per_session_hour": 350,
    "feat_pct": 0.40,
    "fix_pct": 0.30,
    "peak_hour": 22,
    "ai_assisted_commits": 32
  },
  "authors": {
    "Timur": { "commits": 32, "insertions": 2400, "deletions": 300, "test_ratio": 0.41, "top_area": "browse/" },
    "Alice": { "commits": 12, "insertions": 800, "deletions": 150, "test_ratio": 0.35, "top_area": "app/services/" }
  },
  "version_range": ["1.16.0.0", "1.16.1.0"],
  "streak_days": 47,
  "tweetable": "Week of Mar 1: 47 commits (3 contributors), 3.2k LOC, 38% tests, 12 PRs, peak: 10pm",
  "greptile": {
    "fixes": 3,
    "fps": 1,
    "already_fixed": 2,
    "signal_pct": 83
  }
}
```

When command 16 printed `PRS_UNAVAILABLE`, write `"prs_merged": null`, never `0`: a zero reads as a window with no merges, and a later trend comparison would count it as a real drop.

**Note:** Only include the `greptile` field if `<STATE_ROOT>/greptile-history.md` exists and has entries within the time window. Only include the `backlog` field if `TODOS.md` exists. Only include the `test_health` field if test files were found (command 10 returns > 0). If any has no data, omit the field entirely.

Include test health data in the JSON when test files exist:
```json
  "test_health": {
    "total_test_files": 47,
    "regression_test_commits": 3,
    "test_files_changed": 8
  }
```

Include backlog data in the JSON when TODOS.md exists:
```json
  "backlog": {
    "total_open": 28,
    "p0_p1": 2,
    "p2": 8,
    "completed_this_period": 3,
    "added_this_period": 1
  }
```

### Step 14: Write the Narrative

Structure the output as:

---

**Tweetable summary** (first line, before everything else):
```
Week of Mar 1: 47 commits (3 contributors), 3.2k LOC, 38% tests, 12 PRs, peak: 10pm | Streak: 47d
```

## Engineering Retro: [date range]

### Summary Table
(from Step 2)

### Trends vs Last Retro
(from Step 12, loaded before save — skip if first retro)

### Time & Session Patterns
(from Steps 3-4)

Narrative interpreting what the team-wide patterns mean:
- When the most productive hours are and what drives them
- Whether sessions are getting longer or shorter over time
- Estimated hours per day of active coding (team aggregate)
- Notable patterns: do team members code at the same time or in shifts?

### Shipping Velocity
(from Steps 5-7)

Narrative covering:
- Commit type mix and what it reveals
- PR size distribution and what it reveals about shipping cadence
- Fix-chain detection (sequences of fix commits on the same subsystem)
- Version bump discipline

### Code Quality Signals
- Test LOC ratio trend
- Hotspot analysis (are the same files churning?)
- Greptile signal ratio and trend (if history exists): "Greptile: X% signal (Y valid catches, Z false positives)"

### Test Health
- Total test files: N (from command 10)
- Test files changed this period: M (from command 13)
- Regression test commits: list `test(qa):` and `test(design):` and `test: coverage` commits from command 11
- If prior retro exists and has `test_health`: show delta "Test files: {last} → {now} (+{delta})"
- If test ratio < 20%: flag as growth area — "100% test coverage is the goal. Tests make vibe coding safe."

### Plan Completion
Check review JSONL logs for plan completion data from /ship runs this period:

```bash
setopt +o nomatch 2>/dev/null || true  # zsh compat
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
cat "${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/"*-reviews.jsonl 2>/dev/null | grep '"skill":"ship"' | grep '"plan_items_total"' || echo "NO_PLAN_DATA"
```

If plan completion data exists within the retro time window:
- Count branches shipped with plans (entries that have `plan_items_total` > 0)
- Compute average completion: sum of `plan_items_done` / sum of `plan_items_total`
- Identify most-skipped item category if data supports it

Output:
```
Plan Completion This Period:
  {N} branches shipped with plans
  Average completion: {X}% ({done}/{total} items)
```

If no plan data exists, skip this section silently.

### Focus & Highlights
(from Step 8)
- Focus score with interpretation
- Ship of the week callout

### Your Week (personal deep-dive)
(from Step 9, for the current user only)

This is the section the user cares most about. Include:
- Their personal commit count, LOC, test ratio
- Their session patterns and peak hours
- Their focus areas
- Their biggest ship
- **What you did well** (2-3 specific things anchored in commits)
- **Where to level up** (1-2 specific, actionable suggestions)

### Team Breakdown
(from Step 9, for each teammate — skip if solo repo)

For each teammate (sorted by commits descending), write a section:

#### [Name]
- **What they shipped**: 2-3 sentences on their contributions, areas of focus, and commit patterns
- **Praise**: 1-2 specific things they did well, anchored in actual commits. Be genuine — what would you actually say in a 1:1? Examples:
  - "Cleaned up the entire auth module in 3 small, reviewable PRs — textbook decomposition"
  - "Added integration tests for every new endpoint, not just happy paths"
  - "Fixed the N+1 query that was causing 2s load times on the dashboard"
- **Opportunity for growth**: 1 specific, constructive suggestion. Frame as investment, not criticism. Examples:
  - "Test coverage on the payment module is at 8% — worth investing in before the next feature lands on top of it"
  - "Most commits land in a single burst — spacing work across the day could reduce context-switching fatigue"
  - "All commits land between 1-4am — sustainable pace matters for code quality long-term"

**AI collaboration note:** If many commits have `Co-Authored-By` AI trailers (e.g., Claude, Copilot), note the AI-assisted commit percentage as a team metric. Frame it neutrally — "N% of commits were AI-assisted" — without judgment.

### Top 3 Team Wins
Identify the 3 highest-impact things shipped in the window across the whole team. For each:
- What it was
- Who shipped it
- Why it matters (product/architecture impact)

### 3 Things to Improve
Specific, actionable, anchored in actual commits. Mix personal and team-level suggestions. Phrase as "to get even better, the team could..."

### 3 Habits for Next Week
Small, practical, realistic. Each must be something that takes <5 minutes to adopt. At least one should be team-oriented (e.g., "review each other's PRs same-day").

### Week-over-Week Trends
(if applicable, from Step 10)

---

## Compare Mode

When the user runs `/retro compare` (or `/retro compare 14d`):

1. Compute metrics for the current window (default 7d) using the midnight-aligned start date (same logic as the main retro — e.g., if today is 2026-03-18 and window is 7d, use `--since="2026-03-11T00:00:00"`)
2. Compute metrics for the immediately prior same-length window using both `--since` and `--until` with midnight-aligned dates. `--until` is inclusive, so the prior window ends one second before the current start (e.g., for a 7d window starting 2026-03-11: prior window is `--since="2026-03-04T00:00:00" --until="2026-03-10T23:59:59"`). Run command 16 for the prior window with `<start-date>` 2026-03-04 and `<end-date>` 2026-03-10, so its merged PRs/MRs stop where the current window starts. Streaks, the Step 0.5 freshness guard and the history ledger apply to the current window only; where a prior value is zero, the delta shows "N/A" instead of a percentage.
3. Show a side-by-side comparison table with deltas and arrows
4. Write a brief narrative highlighting the biggest improvements and regressions
5. Save only the current-window snapshot to `.context/retros/` (same as a normal retro run); do **not** persist the prior-window metrics.

## Tone

- Encouraging but candid, no coddling
- Specific and concrete — always anchor in actual commits/code
- Skip generic praise ("great job!") — say exactly what was good and why
- Frame improvements as leveling up, not criticism
- **Praise should feel like something you'd actually say in a 1:1** — specific, earned, genuine
- **Growth suggestions should feel like investment advice** — "this is worth your time because..." not "you failed at..."
- Never compare teammates against each other negatively. Each person's section stands on its own.
- Keep total output around 3000-4500 words (slightly longer to accommodate team sections)
- Use markdown tables and code blocks for data, prose for narrative
- Output directly to the conversation — do NOT write to filesystem (except the `.context/retros/` JSON snapshot)

## Important Rules

- ALL narrative output goes directly to the user in the conversation. The ONLY file written is the `.context/retros/` JSON snapshot.
- Use `origin/<default>` for all git queries (not local main which may be stale). When Step 1 could not resolve it, use the `RETRO_REF` fallback and disclose which ref was analyzed.
- Display all timestamps in the user's local timezone (do not override `TZ`)
- If the window has zero commits, say so and suggest a different window
- Round LOC/hour to nearest 50
- Treat merge commits as PR boundaries
- Do not read CLAUDE.md or other docs — this skill is self-contained
- On first run (no prior retros), skip comparison sections gracefully

---

{{include lib/snippets/capture-learnings.md}}
