# Claude Code Usage

How to use Claude Code's own features. This file is the single source for tool
conventions; `CLAUDE.md` carries only the one-line summary.

## Plan Mode

**Enter plan mode before meaningful implementation.**

- New features, behavior changes, structural changes touching more than one
  place, refactors, and ambiguous requests all get a plan first.
- Flow: `EnterPlanMode` → explore and design → `ExitPlanMode` to request
  approval → implement after approval.
- The plan states: understanding of the problem, scope of change, how it will be
  verified, and the risks.
- Skip it for typos, one-line fixes, pure exploration, wording corrections, and
  simple tasks that arrived with detailed instructions.
- If the user clearly asked for immediate implementation and the change is
  low-risk, confirm the context you need and go.

## Subagents

- Delegate independent exploration, analysis, and verification — especially
  broad searches that would otherwise flood the main context.
- Never invoke an agent you have not confirmed exists. Guessing at a name fails
  the call and wastes a turn.
- A subagent does not see this file or `CLAUDE.md`. Put the criteria, exclusion
  patterns, and expected output format directly in its prompt.
- Launch independent agents in a single message so they run concurrently.

## Skills

- When the user types `/<name>`, invoke it through the Skill tool. Do not
  paraphrase the workflow yourself.
- Never guess at a skill that is not installed. See `rules/skills.md` for the
  task → skill map.
- A skill's own instructions take precedence once it is invoked.

## Task Tracking

- Work spanning three or more steps gets tracked as tasks.
- Mark a task `in_progress` immediately *before* starting it and `completed`
  immediately *after* finishing it — not in a batch at the end.
- One task in progress at a time.

## Parallel Tool Calls

- Independent Bash, Read, Grep, and Glob calls go in one message.
- Sequence them only when a later call needs an earlier result.

## Confirming Risky Actions

Confirm with the user before anything externally visible or hard to reverse:

- `rm -rf`, destructive database operations, infrastructure teardown
- `git push --force`, branch deletion, history rewrites
- Opening or commenting on a PR or issue, sending anything to an external
  service

## Context Window

- Avoid large refactors and multi-file feature work in the last ~20% of the
  context window.
- Delegate large exploration to a subagent rather than reading everything into
  the main context.
- Single-file edits, standalone utilities, and doc updates are safe late in the
  window.
