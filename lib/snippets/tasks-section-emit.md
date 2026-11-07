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
- Effort shows both a human-team and a CC estimate. Derive CC time from the
  human estimate with these default ratios (human ÷ CC): scaffolding ~100x,
  tests ~50x, features ~30x, bug fix with regression test ~20x, architecture
  ~5x, research ~3x. Adjust to the actual work and state the ratio you assumed.

### JSONL artifact (always write, even if zero tasks)

`/autoplan` reads this artifact to aggregate across phases. Task text never
passes through a shell command: you write the rows to a file, then one block
validates and stamps them.

The phase identifier is derived from this skill's name: strip the `plan-`
prefix from `{SKILL_NAME}` (e.g. `plan-ceo-review` → `ceo-review`). The
aggregator in `/autoplan` iterates over `ceo-review`, `design-review`,
`eng-review`, `devex-review` and reads `tasks-<phase>-*.jsonl` files.

**1. Get the rows path.** Each run gets its own file: worktrees of one repo
share this directory, and a fixed name would let two runs of the same phase
read each other's rows.

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
PHASE="${SKILL_NAME:-{SKILL_NAME}}"
PHASE="${PHASE#plan-}"
TASKS_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
mkdir -p "$TASKS_DIR"
echo "TASKS_ROWS: $(mktemp "$TASKS_DIR/rows-${PHASE}.XXXXXXXX")"
```

**2. Write the rows** with the Write tool to the printed `TASKS_ROWS` path (Read
the empty file first), one
JSON object per line, one line per task: `id` (T1, T2, ...), `priority`
(P1/P2/P3), `component`, `files` (array of paths), `effort_human`, `effort_cc`,
`title`, `source_finding` — all strings except `files`. With zero tasks, write
nothing.

**3. Validate and stamp** — run this even with zero tasks, substituting the
printed `TASKS_ROWS` path:

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
PHASE="${SKILL_NAME:-{SKILL_NAME}}"
PHASE="${PHASE#plan-}"
TASKS_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
# Zero-padded so two runs in the same second still order as numbers.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%010d' "$$")"
python3 -I - '<TASKS_ROWS>' "$TASKS_DIR/tasks-${PHASE}-${RUN_ID}.jsonl" \
  "$PHASE" "$RUN_ID" "$(git branch --show-current 2>/dev/null || echo unknown)" \
  "$(git rev-parse HEAD 2>/dev/null || echo unknown)" <<'PY'
import json, os, sys
rows_path, out_path, phase, run_id, branch, commit = sys.argv[1:7]
stamp = {"phase": phase, "run_id": run_id, "branch": branch, "commit": commit}
keys = ("id", "priority", "component", "effort_human", "effort_cc", "title", "source_finding")
try:
    lines = open(rows_path, encoding="utf-8").read().splitlines()
except OSError as e:
    # Step 1 always creates the file; a missing one is a wrong path, never
    # "zero tasks" — that would stamp an empty marker over real findings.
    print("TASKS_ROWS_INVALID cannot read %s (%s)" % (rows_path, e.strerror))
    sys.exit(1)
rows, errors = [], []
for n, line in enumerate(lines, 1):
    if not line.strip():
        continue
    try:
        row = json.loads(line)
    except ValueError as e:
        errors.append("line %d: not JSON (%s)" % (n, e))
        continue
    if not isinstance(row, dict):
        errors.append("line %d: not an object" % n)
        continue
    bad = {k for k in keys if not isinstance(row.get(k), str) or not row[k].strip()}
    if row.get("priority") not in ("P1", "P2", "P3"):
        bad.add("priority")
    if not isinstance(row.get("files"), list) or not all(isinstance(f, str) for f in row["files"]):
        bad.add("files")
    if bad:
        errors.append("line %d: bad %s" % (n, ", ".join(sorted(bad))))
        continue
    rows.append(dict(stamp, files=row["files"], **{k: row[k] for k in keys}))
if errors:
    for e in errors:
        print("TASKS_ROWS_INVALID " + e)
    sys.exit(1)
out = rows or [dict(stamp, empty=True)]
with open(out_path + ".tmp", "w", encoding="utf-8") as fh:
    fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in out)
os.replace(out_path + ".tmp", out_path)
if os.path.exists(rows_path):
    os.remove(rows_path)
print("TASKS_FILE: %s (%d tasks)" % (out_path, len(rows)))
PY
```

On `TASKS_ROWS_INVALID`, fix the named lines in the rows file (or the path) and
re-run step 3; nothing was stamped. A run with zero tasks stamps one `"empty": true` marker
row, so the aggregator sees that this phase ran and found nothing, and the
tasks from an earlier run of the phase stop counting.
