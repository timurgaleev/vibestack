---
name: improve-arch
description: |
  Find shallow modules and propose refactors that make them deep: small interface, deep implementation.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Agent
  - AskUserQuestion
triggers:
  - improve architecture
  - find refactoring opportunities
  - deepen modules
  - architecture review
  - make this more testable
---

If this session was compacted, the copy of this skill in context may be cut off.
Read `${CLAUDE_SKILL_DIR}/SKILL.md` from disk and resume at the step you are on.

## When to invoke

Use when asked to "improve architecture", "find refactoring opportunities", "deepen modules", "consolidate tightly-coupled modules", or to make a codebase more testable and AI-navigable.

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

# Improve Codebase Architecture

Surface architectural friction and propose **deepening opportunities** — refactors that turn shallow modules into deep ones. The aim is testability and AI-navigability.

## Glossary

Use these terms exactly in every suggestion. Consistent language is the point — don't drift into "component," "service," "API," or "boundary." Full definitions in [LANGUAGE.md](LANGUAGE.md).

- **Module** — anything with an interface and an implementation (function, class, package, slice).
- **Interface** — everything a caller must know to use the module: types, invariants, error modes, ordering, config. Not just the type signature.
- **Implementation** — the code inside.
- **Depth** — leverage at the interface: a lot of behaviour behind a small interface. **Deep** = high leverage. **Shallow** = interface nearly as complex as the implementation.
- **Seam** — where an interface lives; a place behaviour can be altered without editing in place. (Use this, not "boundary.")
- **Adapter** — a concrete thing satisfying an interface at a seam.
- **Leverage** — what callers get from depth.
- **Locality** — what maintainers get from depth: change, bugs, knowledge concentrated in one place.

Key principles (see [LANGUAGE.md](LANGUAGE.md) for the full list):

- **Deletion test**: imagine deleting the module. If complexity vanishes, it was a pass-through. If complexity reappears across N callers, it was earning its keep.
- **The interface is the test surface.**
- **One adapter = hypothetical seam. Two adapters = real seam.**

This skill is _informed_ by the project's domain model. The domain language gives names to good seams; ADRs record decisions the skill should not re-litigate.

## Process

### 1. Scope first

Decide where to look before looking. A refactor in code nobody touches rarely pays for itself, so the scope is either a **named direction** — the module, feature or pain the user pointed at — or, when the user named none, the files that change most:

```bash
git log --since="6 months ago" --name-only --pretty=format: | grep -v '^$' | sort | uniq -c | sort -rn | head -20
```

Widen the window for a quiet repo, narrow it for a busy one. Use the direction, or these hotspots, to seed the Explore brief in step 2. Say which scope you used in one line before exploring.

### 2. Explore

Read the project's domain glossary first: `GLOSSARY.md` if it exists, else `CONTEXT.md`. A repo with several bounded contexts may keep a `CONTEXT-MAP.md` listing them — pick the context the scope lives in and read that context's glossary, not every one. Read the ADRs (`docs/adr/`) too.

Then use the Agent tool with `subagent_type=Explore` to walk the scoped part of the codebase. Don't follow rigid heuristics — explore organically and note where you experience friction:

{{include lib/snippets/foreground-dispatch.md}}

- Where does understanding one concept require bouncing between many small modules?
- Where are modules **shallow** — interface nearly as complex as the implementation?
- Where have pure functions been extracted just for testability, but the real bugs hide in how they're called (no **locality**)?
- Where do tightly-coupled modules leak across their seams?
- Which parts of the codebase are untested, or hard to test through their current interface?

Apply the **deletion test** to anything you suspect is shallow: would deleting it concentrate complexity, or just move it? A "yes, concentrates" is the signal you want.

### 3. Present candidates

Present a numbered list of deepening opportunities. For each candidate:

- **Files** — which files/modules are involved
- **Problem** — why the current architecture is causing friction
- **Solution** — plain English description of what would change
- **Benefits** — explained in terms of locality and leverage, and also in how tests would improve
- **Strength** — **Strong** (the deletion test and the hotspot data both point here), **Worth exploring** (real friction, unclear payoff) or **Speculative** (a hunch the exploration did not confirm)
- **Dependencies** — the dependency category from [DEEPENING.md](DEEPENING.md) (in-process, local-substitutable, remote but owned, true external), which decides how the deepened module gets tested

**Use the project's domain vocabulary (from the glossary, if one exists) for domain concepts, and [LANGUAGE.md](LANGUAGE.md) vocabulary for the architecture.** If the domain says "Order," talk about "the Order intake module" — not "the FooBarHandler," and not "the Order service."

**ADR conflicts**: if a candidate contradicts an existing ADR, only surface it when the friction is real enough to warrant revisiting the ADR. Mark it clearly (e.g. _"contradicts ADR-0007 — but worth reopening because…"_). Don't list every theoretical refactor an ADR forbids.

End the list with one line:

`Top recommendation: <candidate> because <one line>`

Do NOT propose interfaces yet. Ask which candidate to explore as a decision brief, one option per candidate, with the top recommendation marked `(recommended)`.

### 4. Grilling loop

Once the user picks a candidate, walk the design tree with them — constraints, dependencies, the shape of the deepened module, what sits behind the seam, what tests survive. Run it the same way every time:

1. Keep a numbered frontier of open decisions and ask one at a time, each with a `Recommended:` answer worded so that a plain yes accepts it.
2. Never ask what the code can answer. Look facts up yourself, or dispatch an Explore subagent with `run_in_background: false` and wait for it.
3. Cross-check what the user says the code does against the code; when they differ, show the difference before deciding.
4. For each term the design introduces, walk one edge-case scenario through it to prove the name holds.
5. Stop when no open decision remains, and confirm the resulting design with the user in one summary.

Side effects happen inline as decisions crystallize:

- **Naming a deepened module after a concept not yet documented?** Add the term to the glossary (`GLOSSARY.md`, else `CONTEXT.md`). Create `GLOSSARY.md` lazily if neither exists.
- **Sharpening a fuzzy term during the conversation?** Update the glossary right there.
- **Two rules for every glossary entry.** Domain words only — a term goes in only if it is a word a domain expert would say, never a class name or implementation detail. One word per concept — when two words name the same thing, keep one and list the other under _Avoid_.
- **User rejects the candidate, or settles a decision, with a load-bearing reason?** Offer an ADR only when the decision is hard to reverse, would be surprising without context, and came from a real trade-off; skip ephemeral reasons ("not worth it right now") and self-evident ones. On yes, hand off to `/document-generate --adr` with the decision and its reason — this skill never writes the ADR itself.
- **Want to explore alternative interfaces for the deepened module?** See [INTERFACE-DESIGN.md](INTERFACE-DESIGN.md).
