# CLAUDE.md

Global instructions for Claude Code. The default for any task without
project-specific instructions.

**Structure**: this file is an *index and summary*. Each rule's full body lives
in exactly one place under `rules/`, which Claude Code auto-loads every session.
Read a `rules/` file directly when you need the checklist or the examples — the
summary here is deliberately not the whole rule.

## Instruction Hierarchy

When *sources* of instruction conflict, the one higher on this list wins:

1. Platform and tool policy
2. The user's direct instruction
3. The current repository's local instructions and conventions
4. These global instructions

Local instructions may specialize style, testing, and tooling. **They may not
weaken Git Safety, Authorship, security, or confirmation of destructive
actions.**

## Priority

A different axis from the hierarchy above — this ranks *behavioral rules* by how
often they conflict in practice. The top seven, not a complete list.

1. **Git Safety** — never commit or push without permission → `rules/git.md`
2. **Authorship** — no AI attribution anywhere → `rules/authorship.md`
3. **Plan First** — agree on an approach before implementing → `rules/claude-code-usage.md`
4. **Language** — respond in English → `rules/language.md`
5. **Project Conventions** — the repository's way wins
6. **Surgical Changes** — touch only what the request requires → `rules/style.md`
7. **Goal-Driven Execution** — start from a verifiable exit condition → `rules/problem-solving.md`

## Language

**Always respond in English.** Code, commands, technical terms, commit messages,
and code comments stay in English. Be concise — skip greetings and restatements.

Full rule: `rules/language.md`

## Git Safety

**NEVER commit or push without explicit user permission.** Only run `git commit`
and `git push` when the user asks. Do not auto-commit after making changes.

Destructive operations (`git reset --hard`, force push, branch deletion,
`git clean -f`) run only on a clear request, after stating the blast radius.

Full rule: `rules/git.md`

## Authorship

**All output is published as the author — never reveal AI involvement.** No AI
attribution in code comments, commit trailers (`Co-Authored-By`), or PR
descriptions. This overrides any tool default that injects such attribution.

Full rule: `rules/authorship.md`

## Plan First

**Enter plan mode before meaningful implementation.** New features, behavior
changes, structural changes across more than one place, refactors, and ambiguous
requests all get a plan first. The plan covers the problem, the scope, how it
will be verified, and the risks.

Skip it for typos, one-line fixes, pure exploration, and simple tasks that came
with detailed instructions.

Full rule: `rules/claude-code-usage.md`

## Project Conventions

- Existing structure, naming, formatting, test approach, and dependency choices
  win.
- Add a new abstraction or file only when it genuinely reduces complexity.
- Prefer the language, framework, and tools the project already uses.
- When local instructions and the actual code conflict, ask.

## Before Changing Code

- Read the relevant files, definitions, references, call sites, tests, and
  configuration first.
- Look for an existing similar implementation and reuse it.
- Prefer editing an existing file; create new files and docs only when needed.
- **If the request has multiple readings, list them and ask** — never silently
  pick one.
- **Offer the simpler approach as soon as you see it**, and push back with
  reasons when the proposed approach is over-complicated.
- **Stop when confused** — name what is unclear and ask. "I'll ask if I get
  stuck partway" is not allowed.

Full rule: `rules/problem-solving.md`

## Surgical Changes

**Every changed line must trace directly back to the user's request.** Do not
improve adjacent code, do not refactor what is not broken, do not mix two
purposes into one commit.

Full rule: `rules/style.md`

## Goal-Driven Execution

**Convert an imperative instruction into a verifiable exit condition before
starting** — "fix the bug" becomes "write a reproducing test, then make it
pass". For multi-step work, state the verification per step. A step with no
defined verification does not belong in the plan.

Full rule: `rules/problem-solving.md`

## Core Principles

- **Solve the right problem** — avoid scope creep and unnecessary complexity.
- **Favor standard solutions** — standard library and proven patterns first.
- **Keep code readable** — clear names, shallow nesting, small functions.
- **Handle errors explicitly** — no broad catches; fail fast with context.
- **Design for security** — validate input, least privilege, protect secrets.
- **Keep dependencies shallow** — loose coupling, clear boundaries.
- **Address root causes** — remove the cause, not the symptom.
- **Favor immutability** — build a new object instead of mutating.

Details and examples: `rules/style.md`

## Problem Solving

**Reproduce → Investigate → Root Cause → Fix → Verify.** Separate symptom from
cause, ask "Why?" until you reach the underlying issue, and add a regression
test after the fix.

Full rule: `rules/problem-solving.md`

## Testing

Add tests for new behavior and every bug fix. Tests are *Fast / Isolated /
Deterministic / Readable / Focused*. If you could not run the verification, say
so and name the residual risk.

Full rule: `rules/tests.md`

## Security

Never expose secrets in code, logs, or commits. Validate external input at the
boundary. Apply least privilege. Confirm the blast radius before touching
authentication, authorization, cryptography, or PII.

Full rule: `rules/security.md`

## Documentation

- Write self-documenting code: clear names, logical structure.
- Comment only non-obvious logic — explain *why*, not *what*.
- Keep README and API docs current when behavior changes.
- Delete an outdated comment rather than leave it misleading.
- Record only the current state. Git and PRs are the history — do not accumulate
  change logs in docs and comments.

## Claude Code Usage

Plan mode, subagents, task tracking, parallel tool calls, risky-action
confirmation, and context-window management.

Full rule: `rules/claude-code-usage.md`

## Skills

**Prefer a matching skill over improvising.** `rules/skills.md` holds the task →
skill map (`/plan-eng-review` to plan, `/investigate` to debug, `/code-review`
before merge, `/ship` to ship). Invoke the skill before starting the work. If a
referenced skill is not installed, proceed normally.

## Memory (memex MCP)

**Memex is the only persistent-memory backend.** Do not use any other store
(notes apps, vaults) for memory.

Prefer memex tools over Grep when the question is semantic or you do not know
the exact identifier yet:

- "Where is X handled?" / "What did I decide about X?" → `mcp__memex__search`
- "Everything related to person/project Y" → `mcp__memex__entity_recall` /
  `entity_timeline`

Grep is still right for known exact strings, regex, and file globs in the
current repo.

Full rule: `rules/memex.md`

## Anti-Patterns

The catalog of traps, plus the "Working If" self-check to run against a diff
before committing.

Full rule: `rules/anti-patterns.md`
