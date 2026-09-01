## Working protocols

### Completion status

When you finish a skill workflow, report status as one of:

- **DONE** — completed, with evidence.
- **DONE_WITH_CONCERNS** — completed, but list the concerns.
- **BLOCKED** — cannot proceed; state the blocker and what you tried.
- **NEEDS_CONTEXT** — missing info; state exactly what is needed.

Escalate after 3 failed attempts, on uncertain security-sensitive changes, or on
scope you cannot verify. Format: `STATUS`, `REASON`, `ATTEMPTED`, `RECOMMENDATION`.

### Claimed limitations need evidence

Never assert that something cannot be done, is unsupported, or is unavailable
until you have tried it and can name the command you ran and what it printed. A
limitation stated from assumption is a guess wearing the costume of a fact, and
unlike a wrong answer it does not get corrected — it closes the question, and the
user plans around a wall that isn't there. `BLOCKED` is only honest when
`ATTEMPTED` holds a real attempt. Where one command, one file read, or one search
would settle it, run the probe first; where you genuinely cannot verify, say what
you don't know and what would settle it instead of asserting the limit.

### Confusion protocol

For high-stakes ambiguity (architecture, data model, destructive scope, missing
context), STOP. Name it in one sentence, give 2-3 options with tradeoffs, and
ask. Don't invoke this for routine or obviously-correct changes.

### Context health

During a long session, periodically write a brief `[PROGRESS]` note: done, next,
surprises. If you are looping on the same diagnostic, the same file, or failed
fix variants, STOP and reassess — escalate or run `/context-save`. Progress notes
must NEVER mutate git state.

### Context recovery (session start / after compaction)

Recover recent project context from local artifacts:

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_PROJ="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
if [ -d "$_PROJ" ]; then
  echo "--- RECENT ARTIFACTS ---"
  find "$_PROJ" -maxdepth 1 -type f -name "*.md" 2>/dev/null | xargs ls -t 2>/dev/null | head -3
  _RB=$(git branch --show-current 2>/dev/null | tr '/' '-')
  [ -f "$_PROJ/${_RB}-reviews.jsonl" ] && echo "REVIEWS: $(wc -l < "$_PROJ/${_RB}-reviews.jsonl" | tr -d ' ') entries"
  echo "--- END ARTIFACTS ---"
fi
```

If artifacts are listed, read the newest useful one and give a 2-sentence
"welcome back" summary. For prior decisions and their rationale, query connected
memory (memex) — that is the single source of truth, not a local store.

### Completeness — boil the ocean one lake at a time

AI makes completeness cheap, so the complete thing is the goal: recommend full
coverage (tests, edge cases, error paths). The only thing genuinely out of scope
is unrelated work (rewrites, multi-quarter migrations) — flag that as separate
scope, never as an excuse for a shortcut. Score coverage honestly with
`Completeness: X/10` when options differ in coverage; never fabricate a score.

### Search before building

Before building anything unfamiliar, search first (see the repo's `ETHOS.md`):
**Layer 1** (tried-and-true) — don't reinvent; **Layer 2** (new and popular) —
scrutinize; **Layer 3** (first principles) — prize above all. When
first-principles reasoning contradicts conventional wisdom, name it explicitly.

### Repo ownership — see something, say something

Always flag anything that looks wrong in one sentence (what you noticed + its
impact). How you *act* on an issue outside your current branch follows
`REPO_MODE` (echoed by the preamble): `solo` → you own it, investigate and offer
to fix proactively; `collaborative` / `unknown` → flag it, don't silently fix
(it may be someone else's).
