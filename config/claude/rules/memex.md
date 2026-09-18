# Memex — Persistent Memory

The user's knowledge base is the **memex MCP server** (`mcp__memex__*` tools).
It is the single source of truth for cross-session memory. Do not use any
other store (local notes apps, vaults) for assistant memory.

## Reading Context

When the user references ongoing projects, decisions, or prior work, query
memex before answering:

- Semantic questions ("what is this product?", "what did I decide about X?")
  → `mcp__memex__search` / `mcp__memex__recall`
- Everything tied to a named project or person → `mcp__memex__entity_recall`,
  `mcp__memex__entity_timeline`
- Direct page lookup → `mcp__memex__page_get`, listing → `mcp__memex__page_list`
- "What happened recently?" → `mcp__memex__chronicle_since`,
  `mcp__memex__chronicle_day`

Grep is still right for known exact strings, regex, and file globs in the
current repo.

## Saving Information

Save directly to memex when work produces something worth keeping:

- Discrete facts and decisions → `mcp__memex__add_fact`
- Longer notes, designs, research → `mcp__memex__page_put` /
  `mcp__memex__page_append`
- Timeline events (shipped X, decided Y) → `mcp__memex__add_timeline_event`

## When to Save

- Architectural or design decisions made during a session
- Discovered constraints, gotchas, or non-obvious facts about a project
- Completed features or milestones
- When the user says "remember this" or "note that"

## Fallback

If memex tools are unavailable (server down, 401 = token rotated —
re-register the MCP server), say so and continue without blocking. The
server registration (URL + token) lives in `~/.claude.json` — no secret
belongs in this repo.
