---
name: careful
description: |
  Safety guardrails for destructive commands. Warns before rm -rf, DROP TABLE, force-push, git reset --hard, kubectl delete, and similar destructive operations. User can override each warning; a small catastrophic set (recursive delete of / or the home directory, force-push to the default branch) is hard-denied instead.
allowed-tools:
  - Bash
  - Read
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/careful}/bin/check-careful.sh"
          statusMessage: "Checking for destructive commands..."
triggers:
  - be careful
  - warn before destructive
  - safety mode
  - prod mode
---

## When to invoke

Use when touching prod, debugging live systems, or working in a shared environment. Use when asked to "be careful", "safety mode", "prod mode", or "careful mode".

# /careful — Destructive Command Guardrails

Safety mode is now **active**. Every bash command will be checked for destructive
patterns before running. Most matches warn and are overridable; a small
catastrophic set is blocked outright.

## Two tiers

| Tier | Decision | Applies to |
|------|----------|------------|
| HIGH | `deny` — blocked, not overridable while `/careful` is active | Recursive delete of `/` or the home directory; force-push to the repo's default branch. Only **simple** commands qualify — anything with `;`, `&&`, `||`, a pipe, or a newline falls through to the warn tier, because string matching cannot resolve what a compound command does. `--force-with-lease` never hard-denies. |
| MEDIUM | `ask` — warns, always overridable | Every pattern in the table below. |

This is a best-effort advisory stop, not a policy boundary: it reads the command
as text and cannot out-parse a shell. To lift a HIGH deny, end the `/careful`
session.

## What's protected

| Pattern | Example | Risk |
|---------|---------|------|
| `rm -rf` / `rm -r` / `rm --recursive` | `rm -rf /var/data` | Recursive delete |
| `DROP TABLE` / `DROP DATABASE` | `DROP TABLE users;` | Data loss |
| `TRUNCATE` | `TRUNCATE orders;` | Data loss |
| `git push --force` / `-f` | `git push -f origin main` | History rewrite |
| `git reset --hard` | `git reset --hard HEAD~3` | Uncommitted work loss |
| `git checkout .` / `git restore .` | `git checkout .` | Uncommitted work loss |
| `kubectl delete` | `kubectl delete pod` | Production impact |
| `docker rm -f` / `docker system prune` | `docker system prune -a` | Container/image loss |

## Safe exceptions (no warning)

- `rm -rf node_modules` / `.next` / `dist` / `__pycache__` / `.cache` / `build` / `.turbo` / `coverage`

## Project patterns (additive only)

A project usually has its own destructive commands — a `make nuke-db`, a seed
script, a teardown target. Add warn rules for them, one POSIX ERE per line
(blank lines and `#` comments ignored), in either file:

- `~/.vibestack/careful-patterns.txt` — every repo
- `~/.vibestack/projects/<slug>/careful-patterns.txt` — this repo only

Both are consulted **after** the built-in families, so a pattern file can only
ADD a warning, never suppress a baseline one — a guard a project can silence is
not a guard. A line whose regex the shell cannot compile is skipped, so a typo
never takes the hook down with it.

## How it works

The hook parses the tool payload with a real JSON parser, checks the command
against the patterns above, and returns a `hookSpecificOutput` envelope carrying
`permissionDecision` (`ask` or `deny`) plus `permissionDecisionReason`. The
decision must be nested under `hookSpecificOutput` — Claude Code ignores a
top-level `permissionDecision`, and a hook that emits one silently no-ops.

Two edge rules, opposite by design:

- **Unparseable payload → `ask`.** careful is the ask tier, so an unreadable
  payload prompts rather than passes.
- **Shell obfuscation → `ask`.** `${IFS}` word-splitting and base64-to-shell
  assemble a command the pattern checks never see, so the primitives themselves
  are the signal.

`/freeze`, the deny tier, fails closed on the same unreadable payload. Both
hooks share one extractor (`careful/bin/hook-extract.sh`) so a parsing fix
cannot land in one and miss the other.

## Debug logging

Off unless `VIBESTACK_DEBUG=1`. Switched on, it appends every decision — with
the **full command text** — to `~/.vibestack/hook.log` (rotated at 1MB). Commands
routinely carry API keys and tokens, so turn it on only where that file is an
acceptable audit trail. The usage counter written alongside it records the
decision and the pattern name, never the command.

To deactivate: end the conversation or start a new one. Hooks are session-scoped.
