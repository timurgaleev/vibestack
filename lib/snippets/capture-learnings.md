## Capture Learnings

This step always runs. Before you finish, look back over the session and decide
one of two things: there is a learning worth keeping, or there is not. Both
outcomes have to be stated out loud — a silent skip is not one of them, because
the value of the log comes from every session passing through the same check
rather than only the sessions that happened to remember.

When there is something worth keeping — a non-obvious pattern, pitfall, or
architectural insight — log it for future sessions:

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"{SKILL_NAME}","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern` (reusable approach), `pitfall` (what NOT to do), `preference`
(user stated), `architecture` (structural decision), `tool` (library/framework insight),
`operational` (project environment/CLI/workflow knowledge).

**Sources:** `observed` (you found this in the code), `user-stated` (user told you),
`inferred` (AI deduction), `cross-model` (both Claude and Codex agree).

**Confidence:** 1-10. Be honest. An observed pattern you verified in the code is 8-9.
An inference you're not sure about is 4-5. A user preference they explicitly stated is 10.

**files:** Include the specific file paths this learning references. This enables
staleness detection: if those files are later deleted, the learning can be flagged.

**Only log genuine discoveries.** Don't log obvious things. Don't log things the user
already knows. A good test: would this insight save time in a future session? If yes, log it.

If nothing from this session clears that bar, log nothing and say so in one line —
"no learnings worth logging this session" — so the reader can tell a considered
empty result from a forgotten step. Padding the log to look productive is worse
than an empty result: it dilutes every future search.



