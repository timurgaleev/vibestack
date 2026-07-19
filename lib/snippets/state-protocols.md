## State protocols

### Cross-session decisions

A durable decision (architecture, scope, tool/vendor choice, or a reversal) — not
a turn-level or trivial choice — is recorded so future sessions don't re-litigate
it. When a question touches a past decision ("what did we decide / why / did we
try"), search first:

```bash
~/.vibestack/bin/vibe-decision-search --recent 5 2>/dev/null || true
```

Treat returned decisions as settled calls with their rationale — don't silently
reverse one; if you are about to, say so explicitly. When a new durable decision
is made, log it (`--supersede <id>` for a reversal):

```bash
~/.vibestack/bin/vibe-decision-log '{"decision":"...","rationale":"...","scope":"repo","source":"user"}' 2>/dev/null || true
```

Reliable and local; memory (memex) is the broader semantic-recall layer, not the
decision store.

### Continuous checkpoint mode

When `CHECKPOINT_MODE: continuous` (from the preamble), checkpoint progress with
`WIP:` commits at natural boundaries so a long session survives interruption.
Rules: stage only intentional files (NEVER `git add -A`), never commit broken
tests or mid-edit state, and push only when `CHECKPOINT_PUSH: true`. Don't
announce each WIP commit. When `CHECKPOINT_MODE: explicit` (the default), commit
only when asked. `/ship` squashes `WIP:` commits into their logical commits before
landing.

### Skill routing

If `HAS_ROUTING: yes` was echoed (the repo's `CLAUDE.md` has a `## Skill routing`
section), follow it when deciding which skill to reach for next. Otherwise route
on plain intent. When `PROACTIVE: false`, don't auto-invoke — suggest and ask.

### Question tuning

When `QUESTION_TUNING: true`, honor the user's recorded question preferences:
skip a question whose answer the profile already settles, and respect any
"never ask about X" preference. Manage these with `/plan-tune`. When tuning is
off (the default), ask normally.

**One-way-door safety (always enforced, even with tuning off).** Before
suppressing ANY question because of a preference, classify it — a one-way door
(destructive or irreversible: delete, force-push, drop, rotate a credential,
merge/deploy approval, breaking change) is asked every time and can never be
silenced by a preference:

```bash
~/.vibestack/bin/vibe-question-check --id "<skill>:<question-id>" --skill "<skill>" --category "<approval|clarification|routing>" --summary "<the question text>"
```

Exit 3 / `ONE_WAY` → ask it regardless of preference. Exit 0 / `TWO_WAY` → the
preference may suppress it. If the binary is absent, fail safe: treat the
question as one-way and ask.

### Voice

Speech-to-text invocations are noisy. Treat near-miss aliases of a skill's
trigger phrases as the trigger (e.g. "tech review" → `/plan-eng-review`), and
read digits/symbols spoken as words ("dee one" → `D1`).

### Model overlay

`MODEL_OVERLAY` (from the preamble) names the model family you are running as
(default `claude`; override via `VIBE_MODEL_OVERLAY`). Apply behavior that fits
your own model: lean into your known strengths, and where a skill step has a
known failure mode for your model, prefer the more reliable path. vibestack ships
no heavy per-model patch registry — this is a model-level self-adjustment, not a
file lookup.

### Telemetry (run last)

Telemetry is opt-in and off by default. When enabled (`vibe-config set telemetry
on`), record the skill outcome at the end of the workflow — never blocks:

```bash
~/.vibestack/bin/vibe-telemetry-log --event-type skill_run --skill <skill-name> --outcome <done|blocked|partial> 2>/dev/null || true
```
