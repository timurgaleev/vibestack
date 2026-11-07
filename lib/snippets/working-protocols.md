## Working protocols

### Completion status

When you finish a skill workflow, report status as one of:

- **DONE** — completed, with evidence valid for the final consumed inputs; name
  any reused result and anything not independently verified.
- **DONE_WITH_CONCERNS** — completed, but list the concerns.
- **BLOCKED** — cannot proceed; state the blocker and what you tried.
- **NEEDS_CONTEXT** — missing info; state exactly what is needed.

Escalate after 3 failed attempts, on uncertain security-sensitive changes, or on
scope you cannot verify. Format: `STATUS`, `REASON`, `ATTEMPTED`, `RECOMMENDATION`.

### Claims need evidence

Never assert that something cannot be done, is unsupported, or is unavailable
until you have tried it and can name the command you ran and what it printed. A
limitation stated from assumption closes the question, and the user plans around
a wall that isn't there. `BLOCKED` is only honest when `ATTEMPTED` holds a real
attempt. Where one command, file read, or search would settle it, probe first;
where you cannot, say what you don't know and what would settle it.

- Cite execution as the command plus the revision it ran on, never a run whose
  stderr was silenced.
- Name the evidence kind: a mock or fixture says nothing about the live system.
- Disclose failures and missing coverage; "done, unverified" is not done.
- A checked null result is a result. Agents that agree are one datum.

| Claim | Evidence |
|---|---|
| tests pass | the test command's output on this revision |
| build works | the build's exit status and output |
| bug fixed | the repro failing before the fix, passing after |
| delegated work done | its diff or output, read by you |
| requirements met | each requirement mapped to its proof |

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
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
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
memory (memrain) — that is the single source of truth, not a local store.

### Completeness — cover the requirement, nothing beyond it

The goal is complete coverage of the stated requirement (tests, edge cases,
error paths), with no code beyond it; at equal coverage, prefer the smaller diff.
Adjacent issues are reported, not fixed, and unrelated work (rewrites,
migrations) is separate scope, never an excuse for a shortcut. Score coverage
honestly with `Completeness: X/10` when options differ in coverage; never
fabricate a score.

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
