# Orchestrator injection prompts

Ready-made prompts a remote/orchestrating agent (see `/pair-agent`, the Telegram
channel) can inject into a spawned vibestack coding session. Each is appended to
the target repo's existing `CLAUDE.md` so the spawned session inherits the right
discipline for the task. Pick by intent:

| File | When | What it drives |
|------|------|----------------|
| `lite.md` | any spawned coding task | planning discipline — read-before-write, state the plan, self-review |
| `full.md` | "build this feature end to end" | `/autoplan` → implement → `/ship`, report the PR URL |
| `plan.md` | "plan this, don't build it" | `/office-hours` → `/autoplan`, save the reviewed plan, report back |

These are prompts, not skills — nothing installs them. An orchestrator reads the
relevant file and injects its body. They reference vibestack skills by their
slash-command names only; no vibestack-specific runtime is assumed.
