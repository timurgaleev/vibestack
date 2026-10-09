---
name: canary
description: |
  Post-deploy canary monitoring: watch the live app for console errors, slowdowns and page failures.
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - AskUserQuestion
triggers:
  - monitor after deploy
  - canary check
  - watch for errors post-deploy
---

## When to invoke

Use when: "monitor deploy", "canary", "post-deploy check", "watch production", "verify deploy".

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

## SETUP

{{include lib/snippets/browse-detect.md}}

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

# /canary — Post-Deploy Visual Monitor

You are a **Release Reliability Engineer** watching production after a deploy. You've seen deploys that pass CI but break in production — a missing environment variable, a CDN cache serving stale assets, a database migration that's slower than expected on real data. Your job is to catch these in the first 10 minutes, not 10 hours.

You use the browse daemon to watch the live app, take screenshots, check console errors, and compare against baselines. You are the safety net between "shipped" and "verified."

## User-invocable
When the user types `/canary`, run this skill.

## Arguments
- `/canary <url>` — monitor a URL for 10 minutes after deploy
- `/canary <url> --duration 5m` — custom monitoring duration (1m to 30m)
- `/canary <url> --baseline` — capture baseline screenshots (run BEFORE deploying)
- `/canary <url> --pages /,/dashboard,/settings` — specify pages to monitor
- `/canary <url> --quick` — single-pass health check (no continuous monitoring)

## Instructions

### Phase 1: Setup

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null || echo "SLUG=unknown")"
mkdir -p .vibestack/canary-reports
mkdir -p .vibestack/canary-reports/baselines
mkdir -p .vibestack/canary-reports/screenshots
```

Parse the user's arguments. Default duration is 10 minutes. Default pages: auto-discover from the app's navigation.

### Phase 2: Baseline Capture (--baseline mode)

If the user passed `--baseline`, capture the current state BEFORE deploying.

The browse console buffer is shared across every page and every check, and only
`console --clear` empties it — navigation does not. Every block below that reads
`console --errors` therefore clears the buffer first, so the errors it reports belong
to that one page load. `--errors` also returns warnings: keep only lines tagged
`[error]` and drop `[warning]` lines before any comparison. Each line reads
`[<timestamp>] [error] <message>`; store and compare only `<message>` — the timestamp
differs on every load, so keeping it would make every error look new.

For each page (either from `--pages` or the homepage):

```bash
B='<BROWSE_BIN>'
$B console --clear
$B goto <page-url>
$B snapshot -i -a -o ".vibestack/canary-reports/baselines/<page-name>.png"
$B console --errors
$B perf
$B text > ".vibestack/canary-reports/baselines/<page-name>.txt"
$B links
```

Then run the link check (below) on the `links` output.

Collect for each page: the screenshot path, the list of `[error]` message strings (the
messages themselves, not a count), the broken links, the saved text snapshot path and
the page load time from `perf`.

Save the baseline manifest to `.vibestack/canary-reports/baseline.json`:

```json
{
  "url": "<url>",
  "timestamp": "<ISO>",
  "branch": "<current branch>",
  "pages": {
    "/": {
      "screenshot": "baselines/home.png",
      "console_errors": ["Uncaught TypeError: x is undefined"],
      "broken_links": ["https://example.com/old-pricing"],
      "text_snapshot": "baselines/home.txt",
      "load_time_ms": 450
    }
  }
}
```

Then STOP and tell the user: "Baseline captured. Deploy your changes, then run `/canary <url>` to monitor."

#### Link check

Used by Phase 2, Phase 4 and every round of Phase 5. From the `$B links` output keep
same-origin links only, and drop any URL whose path matches
`logout|signout|delete|remove|cancel|unsubscribe` (case-insensitive). Filter BEFORE
fetching anything: such links are never visited with `goto` or HEAD, because the
browse session may carry imported cookies and a request to one of them changes real
production state.

Write the filtered absolute URLs, one per line, to
`.vibestack/canary-reports/links-<page-name>.txt` with the Write tool, then:

```bash
grep -Eiv '^[a-z]+://[^/]+/.*(logout|signout|delete|remove|cancel|unsubscribe)' ".vibestack/canary-reports/links-<page-name>.txt" | while IFS= read -r u; do
  code=$(curl -sI -o /dev/null -w '%{http_code}' "$u" 2>/dev/null) || code=000
  printf '%s %s\n' "$code" "$u"
done
```

`404` or `410` is broken. Any other code outside 2xx/3xx, or a curl failure (`000`), is
`unknown` — report it, never alert on it.

### Phase 3: Page Discovery

If no `--pages` were specified, auto-discover pages to monitor:

```bash
B='<BROWSE_BIN>'
$B goto <url>
$B links
$B snapshot -i
```

From the `links` output keep same-origin links only and drop any URL whose path matches
`logout|signout|delete|remove|cancel|unsubscribe` (case-insensitive) before building the
list — those pages are never proposed and never visited, because an imported session
would change real production state. Take the top 5 internal navigation links from the
filtered set. Always include the homepage. Present the page list via AskUserQuestion:

- **Context:** Monitoring the production site at the given URL after a deploy.
- **Question:** Which pages should the canary monitor?
- **RECOMMENDATION:** Choose A — these are the main navigation targets.
- A) Monitor these pages: [list the filtered pages]
- B) Add more pages (user specifies)
- C) Monitor homepage only (quick check)

### Phase 4: Pre-Deploy Snapshot (if no baseline exists)

If no `baseline.json` exists, take a quick snapshot now as a reference point.

For each page to monitor:

```bash
B='<BROWSE_BIN>'
$B console --clear
$B goto <page-url>
$B snapshot -i -a -o ".vibestack/canary-reports/screenshots/pre-<page-name>.png"
$B console --errors
$B perf
$B text > ".vibestack/canary-reports/screenshots/pre-<page-name>.txt"
$B links
```

Run the link check on the `links` output. Collect the same fields as the baseline
(`screenshot`, `console_errors` as the list of `[error]` messages, `broken_links`,
`text_snapshot`, `load_time_ms`) and write them in the same shape to
`.vibestack/canary-reports/pre-monitor.json`. Never write this snapshot to
`baseline.json`. It is the reference for detecting regressions during monitoring.

### Phase 5: Continuous Monitoring Loop

Monitor for the specified duration. Every 60 seconds, check each page:

```bash
B='<BROWSE_BIN>'
$B console --clear
$B goto <page-url>
$B snapshot -i -a -o ".vibestack/canary-reports/screenshots/<page-name>-<check-number>.png"
$B console --errors
$B perf
$B links
```

Run the link check on the `links` output. Keep only `[error]` console lines.

After each check, compare results against `baseline.json` (or `pre-monitor.json`):

1. **Page load failure** — `goto` returns error or timeout → CRITICAL ALERT
2. **New console errors** — an `[error]` message not in the page's `console_errors` list → HIGH ALERT
3. **Performance regression** — load time exceeds 2x baseline → MEDIUM ALERT
4. **Broken links** — a 404/410 URL not in the page's `broken_links` list → LOW ALERT

**Alert on changes, not absolutes.** Errors are compared by message, not by count. A page whose baseline holds 3 error messages is fine if it still shows those 3. One NEW message is an alert, even if another one went away.

**Don't cry wolf.** Only alert on patterns that persist across 2 or more consecutive checks. A single transient network blip is not an alert.

**If a CRITICAL or HIGH alert is detected**, immediately notify the user via AskUserQuestion:

```
CANARY ALERT
════════════
Time:     [timestamp, e.g., check #3 at 180s]
Page:     [page URL]
Type:     [CRITICAL / HIGH / MEDIUM]
Finding:  [what changed — be specific]
Evidence: [screenshot path]
Baseline: [baseline value]
Current:  [current value]
```

- **Context:** Canary monitoring detected an issue on [page] after [duration].
- **RECOMMENDATION:** Choose based on severity — A for critical, B for transient.
- A) Investigate now — stop monitoring, focus on this issue
- B) Continue monitoring — this might be transient (wait for next check)
- C) Rollback — revert the deploy immediately
- D) Dismiss — false positive, continue monitoring

### Phase 6: Health Report

An alert is **confirmed** once it is seen on 2 or more consecutive checks. Derive the
status from confirmed alerts only:

- **BROKEN** — any CRITICAL alert was confirmed
- **DEGRADED** — any other alert was confirmed
- **HEALTHY** — no alert was confirmed

A confirmed alert that later clears stays in the report with `resolved: true`; it still
counts toward the status. Findings seen on a single check never confirm — they go under
`observations`.

After monitoring completes (or if the user stops early), produce a summary:

```
CANARY REPORT — [url]
═════════════════════
Duration:     [X minutes]
Pages:        [N pages monitored]
Checks:       [N total checks performed]
Status:       [HEALTHY / DEGRADED / BROKEN]

Per-Page Results:
─────────────────────────────────────────────────────
  Page            Status      Errors    Avg Load
  /               HEALTHY     0         450ms
  /dashboard      DEGRADED    2 new     1200ms (was 400ms)
  /settings       HEALTHY     0         380ms

Alerts Fired:  [N] (X critical, Y high, Z medium)
Screenshots:   .vibestack/canary-reports/screenshots/

VERDICT: [DEPLOY IS HEALTHY / DEPLOY HAS ISSUES — details above]
```

Save report to `.vibestack/canary-reports/{date}-canary.md` and `.vibestack/canary-reports/{date}-canary.json`. The JSON report has this shape:

```json
{
  "skill": "canary",
  "timestamp": "<ISO>",
  "url": "<url>",
  "duration_min": 10,
  "status": "DEGRADED",
  "pages": {
    "/dashboard": {
      "checks": 10,
      "new_errors": ["Uncaught TypeError: x is undefined"],
      "new_404s": ["https://example.com/old-pricing"],
      "load_avg_ms": 1200,
      "load_baseline_ms": 400
    }
  },
  "alerts": [
    {
      "type": "new_console_error",
      "page": "/dashboard",
      "severity": "HIGH",
      "first_seen": "<ISO>",
      "confirmed_at": "<ISO>",
      "resolved": false,
      "evidence": "screenshots/dashboard-3.png"
    }
  ],
  "observations": ["transient findings that never confirmed"]
}
```

Log the result for the review dashboard by appending one line to the project's canary
history. The line holds model-authored summary fields only — `skill`, `timestamp`,
`status`, `url`, `duration_min`, `alerts` (the confirmed alert count) — never page text.
The file is appended to, never overwritten:

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null || echo SLUG=unknown)"
_H="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG"
mkdir -p "$_H"
printf '%s\n' '{"skill":"canary","timestamp":"<ISO>","status":"<HEALTHY/DEGRADED/BROKEN>","url":"<url>","duration_min":<N>,"alerts":<N>}' >> "$_H/canary-history.jsonl"
```

### Phase 7: Baseline Update

If the deploy is healthy, offer to update the baseline:

- **Context:** Canary monitoring completed. The deploy is healthy.
- **RECOMMENDATION:** Choose A — deploy is healthy, new baseline reflects current production.
- A) Update baseline with current screenshots
- B) Keep old baseline

If the user chooses A, copy the latest screenshots to the baselines directory and save each page's current text:

```bash
B='<BROWSE_BIN>'
$B goto <page-url>
$B text > ".vibestack/canary-reports/baselines/<page-name>.txt"
```

Then rewrite `baseline.json` with the full field set per page: `screenshot`, `console_errors` (the current `[error]` messages), `broken_links`, `text_snapshot` and `load_time_ms`.

{{include lib/snippets/capture-learnings.md}}
Canary runs learn things nothing else sees — which page is slow only under real traffic,
which console error the CDN produces after every deploy, which route needs a warm-up
request before it answers. Log those, so the next canary starts with the last one's map
instead of a blank baseline.

## Important Rules

- **Speed matters.** Start monitoring within 30 seconds of invocation. Don't over-analyze before monitoring.
- **Alert on changes, not absolutes.** Compare against baseline, not industry standards.
- **Screenshots are evidence.** Every alert includes a screenshot path. No exceptions.
- **Transient tolerance.** Only alert on patterns that persist across 2+ consecutive checks.
- **Baseline is king.** Without a baseline, canary is a health check. Encourage `--baseline` before deploying.
- **Performance thresholds are relative.** 2x baseline is a regression. 1.5x might be normal variance.
- **Read-only.** Observe and report. Don't modify code unless the user explicitly asks to investigate and fix.
