## Decision brief format (how to ask)

Every AskUserQuestion is a *decision brief*. Send it as a tool call — unless the
fallback below applies, in which case render the same brief as prose.

### Tool resolution (read first)

"AskUserQuestion" can resolve to two tools at runtime: a **host MCP variant**
(e.g. `mcp__<host>__AskUserQuestion`, when the host registers one) or the
**native** tool. If a `mcp__*__AskUserQuestion` variant is in your tool list,
prefer it — some hosts disable the native tool and route through their own, so
calling native there fails silently. The brief format is identical either way.

If `CONDUCTOR_SESSION: true` was echoed by the preamble, do not call
AskUserQuestion at all (native or MCP) — render every brief as the prose form
below. See [session-host](session-host.md).

### When AskUserQuestion is unavailable or a call fails

If no variant is in your tool list, or a call returns an error / missing result:
do NOT silently auto-decide or write the decision into a file as a substitute.
If the tool was present and errored (not absent), retry the same call **once** —
but only if no answer could already have reached the user (a missing-result
error can arrive after they saw the question; retrying would double-prompt).
Then branch on `SESSION_KIND`:

- `headless` → `BLOCKED — AskUserQuestion unavailable`; stop and wait. No human can answer.
- `interactive` (default) → render the **prose fallback**.

### Brief content (tool form)

```
D<N> — <one-line question title>
ELI10: <plain English a 16-year-old could follow, 2-4 sentences, name the stakes>
Stakes if we pick wrong: <one sentence — what breaks, what the user sees, what's lost>
Recommendation: <choice> because <one-line reason>
Completeness: A=X/10, B=Y/10   (or: Note: options differ in kind, not coverage — no score)
A) <label> (recommended)
  ✅ <pro — concrete, observable>
  ❌ <con — honest>
B) <label>
  ✅ <pro>
  ❌ <con>
Net: <one-line synthesis of the real tradeoff>
```

- Number questions yourself: first is `D1`, increment per call. ELI10 and
  Recommendation are ALWAYS present; keep the `(recommended)` marker.
- `Completeness: N/10` only when options differ in *coverage* (10 complete,
  7 happy-path, 3 shortcut). When they differ in *kind*, use the kind-note
  instead — never silently drop the score.
- For 5+ real options, never drop one — see
  [askuserquestion-split](askuserquestion-split.md).

### Prose fallback (interactive, tool unavailable — or Conductor)

Render the same brief as a markdown message, not a tool call. It must surface,
in this order: (1) the **ELI10** of the decision itself, leading; (2) a
**`Completeness: X/10`** on each choice; (3) a **`Recommendation: <choice>
because <reason>`** line. Layout: a `D<N>` title + "reply with a letter", the
ELI10, the Recommendation, then ONE short paragraph per choice (its
`(recommended)` marker, its `Completeness`, 2-4 sentences of reasoning — never a
bare bullet list), and a closing `Net:` line. Then STOP and wait — the typed
answer is the decision. In plan mode this satisfies end-of-turn like a tool call.

A bare letter maps to the single most-recent unanswered brief; if a split chain
left more than one open, ask which `D<N>.k` it answers rather than guessing.

**One-way / destructive confirmations.** When the decision is irreversible or
destructive (delete, force-push, drop, overwrite), prose is a weaker gate than
the tool — make it stronger: require an explicit typed confirmation (the exact
letter or word), state plainly what is irreversible, and never proceed on a
vague or partial reply ("ok"/"sure" without the choice is not confirmation) —
re-ask instead.
