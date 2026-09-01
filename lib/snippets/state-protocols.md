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

**Accepting a shortcut is itself a decision.** When a review, a plan, or a fix
chooses to live with something rather than repair it — a skipped test, a
narrowed scope, a workaround left in place — log that acceptance and put its
*ceiling* in the rationale: the condition that would force revisiting it (a load
level, a second caller, a version bump, a date). Then leave one line at the
shortcut in the code naming the decision id `vibe-decision-log` printed. Both
halves are needed: without the log the ceiling is lost, and without the marker
the next reader finds an unexplained gap and either re-argues it or "fixes"
something that was chosen deliberately.

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

A natural boundary is a test going green, a file finished, a phase of the skill
completing, or the moment before something risky. Give each checkpoint a body,
not just a subject — the subject says what changed, and a session picking the
work back up needs to know where you were standing:

```
WIP: <short subject, what this checkpoint contains>

[vibestack-context]
Done: <what is finished and verified>
Next: <the immediate next step>
Uncertain: <the open question, or "none">
```

Keep the marker line and the three labels exactly as written. `/ship` harvests
these blocks out of the commit bodies before it squashes them away, and a
resuming session finds them with `git log --grep="^WIP:"` — free-form notes in
their place survive the commit but not either reader.

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

**After the user answers, log the event** — best-effort, never blocking. This is
the only thing that writes the log `/plan-tune` reads; without it the whole
question-tuning surface stays empty no matter how many questions get asked. The
log is local, records the option keys rather than the user's prose, and is sent
nowhere:

```bash
~/.vibestack/bin/vibe-question-log '{"skill":"{SKILL_NAME}","question_id":"{SKILL_NAME}:<question-id>","question_summary":"<short>","category":"<approval|clarification|routing>","options_count":N,"user_choice":"<key>","recommended":"<key>"}' 2>/dev/null || true
```

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
