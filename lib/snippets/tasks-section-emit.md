## Implementation Tasks

Before closing this review, synthesize the findings above into a flat list of
build-actionable tasks. Each task derives from a specific finding — no padding.
Emit the markdown section AND write a JSONL artifact that `/autoplan` can
aggregate across phases.

### Markdown section (always emit)

```markdown
## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific
finding above. Run with Claude Code or Codex; checkbox as you ship.

- [ ] **T1 (P1, human: ~2h / CC: ~15min)** — <component> — <imperative title>
  - Surfaced by: <section name> — <specific finding text or line reference>
  - Files: <paths to touch>
  - Verify: <test command or manual check>
- [ ] **T2 (P2, human: ~30min / CC: ~5min)** — ...
```

Rules:
- P1 blocks ship; P2 should land same branch; P3 is a follow-up TODO.
- If a finding produced no actionable task, do not invent one.
- If a section had zero findings, emit `_No new tasks from <section>._`
- Effort uses the AI-compression table from CLAUDE.md.

### JSONL artifact (always write, even if zero tasks)

`/autoplan` reads this file to aggregate across phases. Build each line with
`jq -nc` so titles and source findings containing quotes, newlines, or
backslashes serialize cleanly — never use hand-rolled `echo` / `printf`.

The phase identifier is derived from this skill's name: strip the `plan-`
prefix from `{SKILL_NAME}` (e.g. `plan-ceo-review` → `ceo-review`). The
aggregator in `/autoplan` iterates over `ceo-review`, `design-review`,
`eng-review`, `devex-review` and reads `tasks-<phase>-*.jsonl` files.

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
PHASE="${SKILL_NAME:-{SKILL_NAME}}"
PHASE="${PHASE#plan-}"
TASKS_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
mkdir -p "$TASKS_DIR"
TASKS_FILE="$TASKS_DIR/tasks-${PHASE}-$(date +%Y%m%d-%H%M%S).jsonl"
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
BRANCH=$(git branch --show-current 2>/dev/null || echo unknown)
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

# Repeat ONE jq invocation per task identified during this review.
# Substitute the placeholders inline with shell variables you set per task:
#   TASK_ID (T1, T2, ...), PRIORITY (P1/P2/P3), COMPONENT, TITLE,
#   SOURCE_FINDING, EFFORT_HUMAN, EFFORT_CC, FILES_JSON (a JSON array literal
#   like '["browse/src/sanitize.ts","browse/src/server.ts"]').
if command -v jq >/dev/null 2>&1; then
  jq -nc \
    --arg phase "$PHASE" \
    --arg run_id "$RUN_ID" \
    --arg branch "$BRANCH" \
    --arg commit "$COMMIT" \
    --arg id "$TASK_ID" \
    --arg priority "$PRIORITY" \
    --arg component "$COMPONENT" \
    --arg effort_human "$EFFORT_HUMAN" \
    --arg effort_cc "$EFFORT_CC" \
    --arg title "$TITLE" \
    --arg source_finding "$SOURCE_FINDING" \
    --argjson files "$FILES_JSON" \
    '{phase:$phase, run_id:$run_id, branch:$branch, commit:$commit, id:$id, priority:$priority, component:$component, files:$files, effort_human:$effort_human, effort_cc:$effort_cc, title:$title, source_finding:$source_finding}' \
    >> "$TASKS_FILE"
else
  echo "WARN: jq not installed — skipping JSONL write. Install jq for /autoplan aggregation." >&2
fi
```

If zero tasks were identified in this review, still touch the JSONL file
(`: > "$TASKS_FILE"`) so the aggregator sees that the phase produced output
this run (an empty file means "ran, no findings" — distinct from "didn't run").
