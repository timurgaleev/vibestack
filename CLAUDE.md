# CLAUDE.md — vibestack Development Guide

This file guides development of vibestack itself. Read it before editing skills or tooling.

## Skill structure

Every skill is a directory in `skills/` with a `SKILL.md` and an optional `bin/` directory:

```
skills/my-skill/
├── SKILL.md        # required — frontmatter + instruction body
└── bin/            # optional — hook scripts
    └── check-*.sh
```

### SKILL.md frontmatter

```yaml
---
name: my-skill               # slash command name — no spaces, matches directory name
description: |               # one clear sentence; drives auto-invoke matching
  What this skill does and when to use it.
allowed-tools:               # list only what the skill actually uses
  - Bash
  - Read
  - Edit
  - Write
  - Grep
  - Glob
triggers:                    # phrases that auto-invoke the skill
  - phrase that triggers it
hooks:                       # optional: PreToolUse interceptors
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR}/bin/check.sh"
          statusMessage: "Checking..."
---
```

### Body style

- Write in natural language, not bash. The model follows prose instructions.
- Use `##` sections for phases or major steps.
- Embed an output template so Claude knows exactly how to format results.
- Keep it tight — remove anything the model doesn't need to act on.

## Hook scripts

Hook scripts live in `skills/<name>/bin/`. Rules:

- Read JSON from stdin (the tool call payload from Claude Code)
- Return `{}` to allow the tool call through silently
- Return `{"permissionDecision":"ask","message":"..."}` to pause and ask the user
- Return `{"permissionDecision":"deny","message":"..."}` to block
- Use `#!/usr/bin/env bash` with `set -euo pipefail`
- Use POSIX ERE patterns — `[[:space:]]` not `\s` (macOS BSD sed does not support `\s`)
- Use `^` anchors in sed, not `.*pattern` greedy matches
- Be executable (`chmod +x`)

`${CLAUDE_SKILL_DIR}` points to the installed skill directory at runtime. Reference sibling skills:
```bash
bash "${CLAUDE_SKILL_DIR}/../other-skill/bin/script.sh"
```

### Testing hook scripts directly

```bash
# Safe exception — should return {}
echo '{"tool_input":{"command":"rm -rf node_modules"}}' \
  | bash skills/careful/bin/check-careful.sh

# Dangerous path — should return permissionDecision:ask
echo '{"tool_input":{"command":"rm -rf /var/important"}}' \
  | bash skills/careful/bin/check-careful.sh

# Freeze check with no state file — should return {}
echo '{"tool_input":{"file_path":"/tmp/test.txt"}}' \
  | bash skills/freeze/bin/check-freeze.sh
```

## Session state

Persistent state lives in `~/.vibestack/` (or `$VIBESTACK_HOME`):

```
~/.vibestack/
└── freeze-dir.txt    # written by /freeze, read by check-freeze.sh
```

Naming: descriptive flat files with a `.txt` extension. Always guard reads with `[ -f "$file" ]`. Provide a paired "off" skill to clean up.

## Install and update

```bash
./install     # creates ~/.claude/skills/<name>/, symlinks SKILL.md + bin/
./uninstall   # removes symlinks and empty skill directories
```

The install script symlinks — it never copies. The canonical source is always in this repo. Update flow: `git pull && ./install`. No restart needed if Claude Code supports hot-reload; otherwise start a new session.

## Commit discipline

- One logical change per commit
- Imperative mood: `fix:`, `feat:`, `docs:`, `chore:`
- Good: `fix: safe exception sed — replace \s with [[:space:]] for macOS BSD sed`
- Bad: `update check-careful.sh`

## Adding a skill checklist

- [ ] `skills/<name>/SKILL.md` exists with valid frontmatter
- [ ] `name:` matches the directory name exactly
- [ ] `description:` is one clear sentence (used for auto-invoke matching)
- [ ] `allowed-tools:` lists only what the skill uses
- [ ] If hooks: `bin/` scripts exist, are executable, use POSIX-safe patterns
- [ ] Hook scripts tested manually with `echo '{...}' | bash skills/.../check-*.sh`
- [ ] New session confirms slash command works
- [ ] README skills table updated
- [ ] `./install` runs without errors
