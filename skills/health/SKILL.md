---
name: health
description: |
  Code quality dashboard. Wraps existing project tools (type checker, linter, test runner, dead code detector, shell linter), computes a weighted composite 0-10 score, and tracks trends over time.
triggers:
  - code health check
  - quality dashboard
  - how healthy is codebase
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

## When to invoke

Use when: "health check", "code quality", "how healthy is the codebase", "run all checks", "quality score".

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

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## User-invocable
When the user types `/health`, run this skill.

---

## Step 1: Detect Health Stack

Read CLAUDE.md and look for a `## Health Stack` section. If found, parse the tools
listed there and skip auto-detection.

If no `## Health Stack` section exists, auto-detect available tools:

```bash
# Type checker
[ -f tsconfig.json ] && echo "TYPECHECK: tsc --noEmit"

# Linter
[ -f biome.json ] || [ -f biome.jsonc ] && echo "LINT: biome check ."
setopt +o nomatch 2>/dev/null || true
ls eslint.config.* .eslintrc.* .eslintrc 2>/dev/null | head -1 | xargs -I{} echo "LINT: eslint ."
[ -f .pylintrc ] || [ -f pyproject.toml ] && grep -q "pylint\|ruff" pyproject.toml 2>/dev/null && echo "LINT: ruff check ."

# Test runner
[ -f package.json ] && grep -q '"test"' package.json 2>/dev/null && echo "TEST: $(node -e "console.log(JSON.parse(require('fs').readFileSync('package.json','utf8')).scripts.test)" 2>/dev/null)"
[ -f pyproject.toml ] && grep -q "pytest" pyproject.toml 2>/dev/null && echo "TEST: pytest"
[ -f Cargo.toml ] && echo "TEST: cargo test"
[ -f go.mod ] && echo "TEST: go test ./..."

# Dead code
command -v knip >/dev/null 2>&1 && echo "DEADCODE: knip"
[ -f package.json ] && grep -q '"knip"' package.json 2>/dev/null && echo "DEADCODE: npx knip"

# Shell linting
command -v shellcheck >/dev/null 2>&1 && ls *.sh scripts/*.sh bin/*.sh 2>/dev/null | head -1 | xargs -I{} echo "SHELL: shellcheck"
```

Use Glob to search for shell scripts:
- `**/*.sh` (shell scripts in the repo)

After auto-detection, present the detected tools via AskUserQuestion:

"I detected these health check tools for this project:

- Type check: `tsc --noEmit`
- Lint: `biome check .`
- Tests: `bun test`
- Dead code: `knip`
- Shell lint: `shellcheck *.sh`

A) Looks right -- persist to CLAUDE.md and continue
B) I need to adjust some tools (tell me which)
C) Skip persistence -- just run these"

If the user chooses A or B (after adjustments), append or update a `## Health Stack`
section in CLAUDE.md:

```markdown
## Health Stack

- typecheck: tsc --noEmit
- lint: biome check .
- test: bun test
- deadcode: knip
- shell: shellcheck *.sh scripts/*.sh
```

---

## Step 2: Run Tools

Run each detected tool. For each tool:

1. Record the start time
2. Run the command, capturing complete stdout and stderr in a private temporary log
3. Record the checker's own exit code, before any parser or display command runs
4. Record the end time
5. Count findings from the complete log, then show its last 50 lines for the report

```bash
# Capture one tool. Per tool, set health_tool, the command line and the count pattern.
(
  umask 077
  health_tool=typecheck
  health_pattern='error TS'
  health_capture_error() {
    printf 'TOOL:%s ERROR:capture-%s\n' "$health_tool" "$1"
    exit 125
  }
  health_log=$(mktemp "${TMPDIR:-/tmp}/vibe-health.XXXXXX") || health_capture_error log
  trap 'rm -f -- "$health_log"' EXIT
  health_start=$(date +%s) || health_capture_error timing
  # Open the log first, so a redirection failure cannot pass for a checker result.
  exec 3>"$health_log" || health_capture_error redirection
  if tsc --noEmit >&3 2>&1; then
    health_status=0
  else
    health_status=$?
  fi
  exec 3>&-
  health_end=$(date +%s) || health_capture_error timing
  # awk prints 0 for no matches, so an empty log still yields a count.
  health_count=$(awk -v p="$health_pattern" 'index($0, p) { n++ } END { print n+0 }' "$health_log") || health_capture_error parsing
  tail -50 "$health_log" || health_capture_error display
  printf 'TOOL:%s EXIT:%s DURATION:%ss COUNT:%s\n' "$health_tool" "$health_status" "$((health_end-health_start))" "$health_count"
)
```

`EXIT` is the checker's status, never that of `tail`, `awk` or a pipe. `COUNT` comes
from the whole log, not the 50 lines shown. Swap in the tool's command and the fixed
string that marks one finding (`error TS` for tsc; Step 3 lists the others); for a
tool whose summary line carries the count, read it from the same log.

Run tools sequentially, one block per tool (some share resources or lock files). A
failing checker does not stop the later ones.

**SKIPPED, FAILED or ERROR — decide before and after running:**
- **SKIPPED** — decided *before* running: the tool's binary is absent
  (`command -v <binary>` finds nothing, no local `node_modules/.bin` entry) and no
  `## Health Stack` entry names it. Record the reason. Only a skip redistributes weight.
- **FAILED** — the command ran and could not execute the check: exit 126 or 127
  (typo, missing binary in a configured `## Health Stack` command, no permission).
  It scores 0. A configured command that does not run is a broken check, not a
  missing one, and must never raise the score.
- **ERROR** — the capture itself broke (`TOOL:<name> ERROR:capture-...`: log,
  redirection, timing, parsing or display). The category gets no score, the composite
  is `N/A — capture failed`, and no history row is written.

---

## Step 3: Score Each Category

Score each category on a 0-10 scale using this rubric:

| Category | Weight | 10 | 7 | 4 | 0 |
|-----------|--------|------|-----------|------------|-----------|
| Type check | 25% | Clean (exit 0) | <10 errors | <50 errors | >=50 errors |
| Lint | 20% | Clean (exit 0) | <5 warnings | <20 warnings | >=20 warnings |
| Tests | 30% | All pass (exit 0) | >95% pass | >80% pass | <=80% pass |
| Dead code | 15% | Clean (exit 0) | <5 unused exports | <20 unused | >=20 unused |
| Shell lint | 10% | Clean (exit 0) | <5 issues | >=5 issues | N/A (skip) |

**Parsing tool output for counts:** use the complete captured log (`COUNT` above),
never the displayed tail. A non-zero exit is never `CLEAN` and never 10. Exit 126 or
127 is `FAILED` and scores 0, whatever the log says. Any other non-zero exit whose
full log yields no count scores 4 (as for a test runner that reports only its exit
code); keep its output for the details section.

- **tsc:** Count lines matching `error TS` in output.
- **biome/eslint/ruff:** Count lines matching error/warning patterns. Parse the summary line if available.
- **Tests:** Parse pass/fail counts from the test runner output. If the runner only reports exit code, use: exit 0 = 10, any other non-zero exit except 126/127 = 4 (assume some failures).
- **knip:** Count lines reporting unused exports, files, or dependencies.
- **shellcheck:** Count distinct findings (lines starting with "In ... line").

**Composite score:** compute it in code, never by hand. Pass every category once as
`name=<score>`, where the score is an integer 0-10, `null` for SKIPPED, or `error`
for a capture ERROR. Skipped weight is redistributed proportionally among the
scored categories; the weights are typecheck 25%, lint 20%, test 30%, deadcode 15%,
shell 10%.

```bash
python3 -I -c '
import sys
w = {"typecheck": 0.25, "lint": 0.20, "test": 0.30, "deadcode": 0.15, "shell": 0.10}
s = {}
for a in sys.argv[1:]:
    k, sep, v = a.partition("=")
    if not sep or k not in w or k in s:
        sys.exit("bad argument: " + a)
    if v not in ("null", "error") and not (v.isdigit() and int(v) <= 10):
        sys.exit("bad score for " + k + ": " + v)
    s[k] = v
if set(s) != set(w):
    sys.exit("pass every category: " + " ".join(w))
scored = [k for k in w if s[k] not in ("null", "error")]
errors = [k for k in w if s[k] == "error"]
print("CHECKED: " + (" ".join(scored) or "none"))
print("UNAVAILABLE: " + (" ".join(k for k in w if s[k] == "null") or "none"))
print("COVERAGE: %d/%d" % (len(scored), len(w)))
if errors:
    print("COMPOSITE: N/A - capture failed (" + " ".join(errors) + ")")
elif not scored:
    print("COMPOSITE: N/A - no checks ran")
else:
    c = sum(int(s[k]) * w[k] for k in scored) / sum(w[k] for k in scored)
    print("COMPOSITE: %.1f" % c + ("" if len(scored) == len(w) else " (partial coverage)"))
' typecheck=10 lint=8 test=10 deadcode=7 shell=null
```

Replace the example values with this run's results. Report the `COMPOSITE` line as
printed; a numeric composite exists only when it prints a number.

---

## Step 4: Present Dashboard

Present results as a clear table:

```
CODE HEALTH DASHBOARD
=====================

Project: <project name>
Branch:  <current branch>
Date:    <today>

Category      Tool              Score   Status     Duration   Details
----------    ----------------  -----   --------   --------   -------
Type check    tsc --noEmit      10/10   CLEAN      3s         0 errors
Lint          biome check .      8/10   WARNING    2s         3 warnings
Tests         bun test          10/10   CLEAN      12s        47/47 passed
Dead code     knip               7/10   WARNING    5s         4 unused exports
Shell lint    shellcheck        10/10   CLEAN      1s         0 issues

COMPOSITE SCORE: 9.2 / 10
Coverage: 5/5 categories checked
Checked: typecheck, lint, test, deadcode, shell
Unavailable: none

Duration: 23s total
```

Use these status labels:
- 10: `CLEAN`
- 7-9: `WARNING`
- 4-6: `NEEDS WORK`
- 0-3: `CRITICAL`
- Command could not run (exit 126/127): `FAILED` (scores 0)
- Tool not available: `SKIPPED` (no score)
- Capture broke: `ERROR` (no score; composite is N/A)

Always show the coverage lines. With skipped categories, label the score
`— partial coverage` (e.g. `COMPOSITE SCORE: 8.0 / 10 — partial coverage`,
`Coverage: 2/5 categories checked`) and list each unavailable category with its
reason. When no check ran, show `COMPOSITE SCORE: N/A — no checks ran` and say which
tools need installing or configuring; never show 10/10 for an empty run.

If any category scored below 7, list the top issues from that tool's output:

```
DETAILS: Lint (3 warnings)
  biome check . output:
    src/utils.ts:42 — lint/complexity/noForEach: Prefer for...of
    src/api.ts:18 — lint/style/useConst: Use const instead of let
    src/api.ts:55 — lint/suspicious/noExplicitAny: Unexpected any
```

---

## Step 5: Persist to Health History

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" && mkdir -p ~/.vibestack/projects/$SLUG
```

Only when the composite is numeric, append one JSONL line to
`~/.vibestack/projects/$SLUG/health-history.jsonl`. A run with no checks or a capture
ERROR writes nothing and leaves the existing history as it is:

```json
{"ts":"2026-03-31T14:30:00Z","branch":"main","score":9.2,"typecheck":10,"lint":8,"test":10,"deadcode":7,"shell":10,"duration_s":23}
```

Fields:
- `ts` -- ISO 8601 timestamp
- `branch` -- current git branch
- `score` -- composite score (one decimal)
- `typecheck`, `lint`, `test`, `deadcode`, `shell` -- individual category scores (integer 0-10)
- `duration_s` -- total time for all tools in seconds

If a category was skipped, set its value to `null`.

---

## Step 6: Trend Analysis + Recommendations

Read the last 10 entries from `~/.vibestack/projects/$SLUG/health-history.jsonl` (if the
file exists and has prior entries).

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" && mkdir -p ~/.vibestack/projects/$SLUG
tail -10 ~/.vibestack/projects/$SLUG/health-history.jsonl 2>/dev/null || echo "NO_HISTORY"
```

**Compare like-for-like coverage only.** For each history row, the scored set is the
categories with a non-null value (a missing field counts as null). Report a delta,
`IMPROVING` or `REGRESSIONS DETECTED` only against rows whose scored set equals this
run's exactly. If the previous run's set differs, say **Coverage changed — scores are
not comparable** and label nothing an improvement or a regression; older rows may
still be listed with their unavailable categories marked. An N/A run has no trend.

**If comparable prior entries exist, show the trend:**

```
HEALTH TREND (last 5 runs)
==========================
Date          Branch         Score   TC   Lint  Test  Dead  Shell
----------    -----------    -----   --   ----  ----  ----  -----
2026-03-28    main           9.4     10   9     10    8     10
2026-03-29    feat/auth      8.8     10   7     10    7     10
2026-03-30    feat/auth      8.2     10   6     9     7     10
2026-03-31    feat/auth      9.2     10   8     10    7     10

Trend: IMPROVING (+1.0 since last run)
```

**If score dropped vs the previous run with identical coverage:**
1. Identify WHICH categories declined
2. Show the delta for each declining category
3. Correlate with tool output -- what specific errors/warnings appeared?

```
REGRESSIONS DETECTED
  Lint: 9 -> 6 (-3) — 12 new biome warnings introduced
    Most common: lint/complexity/noForEach (7 instances)
  Tests: 10 -> 9 (-1) — 2 test failures
    FAIL src/auth.test.ts > should validate token expiry
    FAIL src/auth.test.ts > should reject malformed JWT
```

**Health improvement suggestions (always show these):**

Prioritize suggestions by impact (weight * score deficit):

```
RECOMMENDATIONS (by impact)
============================
1. [HIGH]  Fix 2 failing tests (Tests: 9/10, weight 30%)
   Run: bun test --verbose to see failures
2. [MED]   Address 12 lint warnings (Lint: 6/10, weight 20%)
   Run: biome check . --write to auto-fix
3. [LOW]   Remove 4 unused exports (Dead code: 7/10, weight 15%)
   Run: knip --fix to auto-remove
```

Rank by `weight * (10 - score)` descending. Only show categories below 10.

---

{{include lib/snippets/capture-learnings.md}}
The score itself belongs in `health-history.jsonl`, not here. What belongs here is what
you had to work out to produce it: a tool that needs a flag to be parseable, a category
whose count is misleading on this repo, a check that is slow enough to be worth skipping
on a quick pass.

---

## Important Rules

1. **Wrap, don't replace.** Run the project's own tools. Never substitute your own analysis for what the tool reports.
2. **Read-only.** Never fix issues. Present the dashboard and let the user decide.
3. **Respect CLAUDE.md.** If `## Health Stack` is configured, use those exact commands. Do not second-guess.
4. **Skipped is not failed.** Skip only a tool whose absence was established before running, show coverage, and redistribute weight among scored categories only. A command that ran and failed — including exit 127 — is FAILED, never SKIPPED.
5. **Show raw output for failures.** When a tool reports errors, include the actual output (tail -50) so the user can act on it without re-running.
6. **Trends require comparable history.** On the first scored run, say "First health check -- no trend data yet. Run /health again after making changes to track progress." A changed coverage set or an N/A run has no score delta.
7. **Be honest about scores.** A codebase with 100 type errors and all tests passing is not healthy. The composite score should reflect reality.
