## Prior Learnings

Search for learnings from previous sessions, keyed to the work at hand. Before
running the search, pick a `<topic>`: two or three words naming what
{SKILL_NAME} is working on right now (the subsystem, the file area, the symptom).
An unkeyed search returns whatever happened to be logged most recently, which is
usually a different thread of work entirely, so the one entry that bears on this
task gets crowded out by noise from unrelated sessions.

Query terms are matched against each learning's key, insight and file paths. An
entry matches when *any* term hits, and entries hitting more terms rank first, so
an extra synonym widens the net without hiding anything. Prefer the words a past
session would have written down about this subject over the name of the skill you
are running.

```bash
_CROSS_PROJ=$(${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-config get cross_project_learnings 2>/dev/null || echo "unset")
echo "CROSS_PROJECT: $_CROSS_PROJ"
if [ "$_CROSS_PROJ" = "true" ]; then
  ${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search --query "<topic>" --limit 10 --cross-project \
    || echo "LEARNINGS: unavailable (vibe-learnings-search exited $?)"
else
  ${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search --query "<topic>" --limit 10 \
    || echo "LEARNINGS: unavailable (vibe-learnings-search exited $?)"
fi
```

If `CROSS_PROJECT` is `unset` (first time): Use AskUserQuestion:

> vibestack can search learnings from your other projects on this machine to find
> patterns that might apply here. This stays local (no data leaves your machine).
> Recommended for solo developers. Skip if you work on multiple client codebases
> where cross-contamination would be a concern.

Options:
- A) Enable cross-project learnings (recommended)
- B) Keep learnings project-scoped only

If A: run `~/.vibestack/bin/vibe-config set cross_project_learnings true`
If B: run `~/.vibestack/bin/vibe-config set cross_project_learnings false`

Then re-run the search with the appropriate flag.

If the output is `LEARNINGS: unavailable (...)`, the lookup itself failed: say so
in one line, quoting the reason printed above it, and carry on without prior
learnings. Do not report it as "no learnings on record" — that is a different
fact.

If the keyed search comes back with no matches, re-run the same command with
`--query` removed to pull the most recent entries instead. Having nothing on
record for a topic is normal on a young project. Read that fallback batch as
background rather than as findings about this task. A closing
`N more matched, raise --limit to see them` means the shelf holds more on this
topic than was shown; raise `--limit` when the top entries do not settle it.

If learnings are found, incorporate them into your analysis. When a review finding
matches a past learning, display:

**"Prior learning applied: [key] (confidence N/10, from [date])"**

This makes the compounding visible. The user should see that vibestack is getting
smarter on their codebase over time.

