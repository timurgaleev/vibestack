## Capture Learnings

This step always runs. Before you finish, look back over the session and decide
one of two things: there is a learning worth keeping, or there is not. Both
outcomes have to be stated out loud — a silent skip is not one of them, because
the value of the log comes from every session passing through the same check
rather than only the sessions that happened to remember.

When there is something worth keeping — a non-obvious pattern, pitfall, or
architectural insight — log it for future sessions:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-log" '{"skill":"{SKILL_NAME}","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern` (reusable approach), `pitfall` (what NOT to do), `preference`
(user stated), `architecture` (structural decision), `tool` (library/framework insight),
`operational` (project environment/CLI/workflow knowledge).

**key:** letters, digits, `.`, `_` and `-` only, at most 80 characters — kebab-case
works (`retry-backoff-jitter`).

**Sources:** `observed` (you found this in the code), `user-stated` (user told you),
`inferred` (AI deduction), `cross-model` (both Claude and Codex agree).

**Confidence:** 1-10. Be honest. An observed pattern you verified in the code is 8-9.
An inference you're not sure about is 4-5. A user preference they explicitly stated is 10.
Observed and inferred entries lose a point every 30 days at search time, so stale
guesses sink on their own; do not inflate the number to compensate.

**files:** Include the specific file paths this learning references. This enables
staleness detection: if those files are later deleted, the learning can be flagged.

The log validates every field and refuses an insight phrased as an instruction to
the agent ("ignore previous...", "from now on...", "skip the review..."); state the
fact, not a directive. Only `user-stated` entries are visible to other projects'
searches. If the command exits non-zero, the learning was **not** recorded: report
the error line it printed, fix the payload, and re-run — never say it was logged.

**Only log genuine discoveries.** Don't log obvious things. Don't log things the user
already knows. A good test: would this insight save time in a future session? If yes, log it.

If nothing from this session clears that bar, log nothing and say so in one line —
"no learnings worth logging this session" — so the reader can tell a considered
empty result from a forgotten step. Padding the log to look productive is worse
than an empty result: it dilutes every future search.



