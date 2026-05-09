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

## Using shared snippets

Skills can pull in shared markdown sections via include directives.
Put the canonical content in `lib/snippets/<name>.md`, then reference
it from any skill source file:

```
{{include lib/snippets/<name>.md}}
```

Rules for the include directive:

- The directive line must match the regex
  `^\{\{include lib/snippets/[A-Za-z0-9_-]+\.md\}\}$` exactly — no
  leading/trailing whitespace, no comment characters.
- Indented or fenced occurrences are treated as content (so you can
  document the directive inside a ```` ``` ```` code block without
  triggering it).
- Snippets must NOT contain other include directives — v1 supports
  one level only. The renderer detects nested includes and exits 2.
- One token substitution: `{SKILL_NAME}` in snippet content is
  replaced with the source skill's directory basename at render
  time. Use it when a snippet's content needs to embed the skill's
  own name (e.g., the JSON `"skill"` field in a logging command).

When `./install` runs, `bin/vibe-render-skill` expands directives
and writes the rendered file to `~/.claude/skills/<name>/SKILL.md`
as a regular file. A sidecar `.vibe-render.json` is also written
when expansion happened, listing the source path and included parts.

To check whether installed output has drifted from sources:

```bash
bin/vibe-render-skill --check skills/<name>/SKILL.md ~/.claude/skills/<name>/SKILL.md
# exit 0 = no drift; exit 1 = drift; the diff is printed to stderr.
```

## Install and update

```bash
./install     # renders skills into ~/.claude/skills/<name>/SKILL.md
              # (regular files); symlinks bin/ + sub-docs (unchanged)
./uninstall   # removes rendered SKILL.md, sidecar JSON, and symlinks
```

The install script renders `SKILL.md` files via `bin/vibe-render-skill`
and symlinks everything else (`bin/`, sub-docs) for the
"edit source, immediately reflected" workflow. The canonical source
is always in this repo. Update flow: `git pull && ./install`. No
restart needed if Claude Code supports hot-reload; otherwise start
a new session.

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
- [ ] If using shared snippets: directive matches the grammar above; no nested includes
- [ ] New session confirms slash command works
- [ ] README skills table updated
- [ ] `./install` runs without errors
- [ ] `bash test/test-render-skill.sh` passes if the renderer or any snippet was touched
