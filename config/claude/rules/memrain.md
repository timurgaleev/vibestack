# Memrain — Persistent Memory

The user's knowledge base is the **memrain MCP server** (`mcp__memrain__*` tools).
It is the single source of truth for cross-session memory. Do not use any
other store (local notes apps, vaults) for assistant memory.

## Reading Context

When the user references ongoing projects, decisions, or prior work, query
memrain before answering:

- Semantic questions ("what is this product?", "what did I decide about X?")
  → `mcp__memrain__search` / `mcp__memrain__recall`
- Everything tied to a named project or person → `mcp__memrain__entity_recall`,
  `mcp__memrain__entity_timeline`
- Direct page lookup → `mcp__memrain__page_get`, listing → `mcp__memrain__page_list`
- "What happened recently?" → `mcp__memrain__chronicle_since`,
  `mcp__memrain__chronicle_day`

Grep is still right for known exact strings, regex, and file globs in the
current repo.

## Code Questions

When the repo is indexed into memrain, ask its code graph before Grep:

- "Where is X defined?" → `mcp__memrain__code_def`
- "Who calls X?" → `mcp__memrain__code_callers`; every other use (imports,
  type uses) → `mcp__memrain__code_refs`
- "What does this function call?" → `mcp__memrain__code_callees` with
  `<path>:<line>`
- "What breaks if I change X?" → `mcp__memrain__code_blast`; "where does this
  request end up?" → `mcp__memrain__code_flow`

**Zero hits means unknown, not absent.** An empty result is proof only when its
`readiness.state` is `ready`. `not_built`, `indexing` or `no_symbols` — or a
failed call — mean the graph cannot answer: say so, then fall back to Grep.
Never report "nothing calls X" from an empty or failed query.

## Saving Information

Save directly to memrain when work produces something worth keeping:

- Discrete facts and decisions → `mcp__memrain__add_fact`
- Longer notes, designs, research → `mcp__memrain__page_put` /
  `mcp__memrain__page_append`
- Timeline events (shipped X, decided Y) → `mcp__memrain__add_timeline_event`

## When to Save

- Architectural or design decisions made during a session
- Discovered constraints, gotchas, or non-obvious facts about a project
- Completed features or milestones
- When the user says "remember this" or "note that"

## Fallback

If memrain tools are unavailable (server down, 401 = token rotated —
re-register the MCP server), say so and continue without blocking. The
server registration (URL + token) lives in `~/.claude.json` — no secret
belongs in this repo.
