---
name: vibe
description: |
  Router for the vibestack skill suite — name the task and it points you at the right skill. Use when you know vibestack is installed but not which of its skills fits, or when an agent has no slash-command picker (Codex) and needs to find the pack by name.
allowed-tools:
  - Bash
  - Read
triggers:
  - which vibestack skill
  - what vibestack skills are there
  - list vibestack skills
  - vibestack help
  - vibe help
---

## When to invoke

Use when the task clearly wants a vibestack workflow but the right one is not
obvious, or when the host has no slash-command picker and the pack has to be
found by name. In Claude Code, Cursor and Kiro, skills are `/name`. In Codex
there is no `/` picker — reference a skill as `$name` inside an ordinary
message (`Use $office-hours to shape this idea`).

# /vibe — pick the right skill

The router is named `vibe`, not `vibestack`: the pack's own checkout is
sometimes parked at `~/.claude/skills/vibestack`, and a skill installing to that
path would collide with it — the installer's own integration test asserts that
checkout survives.

Route on intent. Process skills come first: brainstorm or plan before
implementing, investigate before fixing, review before shipping.

| When the task is… | Use |
|---|---|
| Shape a rough idea into a design doc | `office-hours` |
| Turn intent into a precise, executable spec | `spec` |
| Plan a feature, refactor, or architecture change | `plan-eng-review`, `autoplan` |
| Weigh product scope or the bigger problem | `plan-ceo-review` |
| Plan a UI change, or review a design before it is built | `plan-design-review` |
| Pressure-test the developer experience of a plan | `plan-devex-review` |
| Implement with tests, red-green-refactor | `tdd` |
| Debug an error, test failure, or odd behavior | `investigate` |
| Review a diff before merge | `review` |
| Get a second opinion from a different model | `codex`, `claude` |
| Audit security | `cso` |
| QA a running web app | `qa` (fixes), `qa-only` (report) |
| Drive a browser, scrape a page, pair a remote agent | `browse`, `scrape`, `open-browser`, `pair-agent` |
| Review a shipped UI, or explore design directions | `design-review`, `design-shotgun`, `design-consultation` |
| Ship: tests, version, changelog, PR | `ship` |
| Merge, deploy, and confirm production health | `land-and-deploy`, `canary` |
| Update docs after shipping | `document-release`, `document-generate` |
| Check code-quality health or find refactors | `health`, `improve-arch` |
| Save or restore working context across sessions | `context-save`, `context-restore` |
| Guard a risky session | `careful`, `freeze`, `guard` (and `unfreeze` to release) |
| Update the pack itself | `vibe-upgrade` |

Anything not listed here is in the full index — read it rather than guessing at
a skill name:

```bash
cat "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/vibe}/skills-index.md" 2>/dev/null \
  || ls ~/.claude/skills/
```

Two rules when routing:

- **Pick one.** Don't stack skills; each carries its own full workflow, and a
  skill's own instructions take precedence once invoked.
- **Don't guess a name.** If nothing above fits, say so and proceed normally —
  these are workflows, not dependencies.
