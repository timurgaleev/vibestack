# Contributing

## Setup

```bash
git clone https://github.com/timurgaleev/tstackvibe
cd tstackvibe
./install
```

No other dependencies. tstackvibe requires only Bash and Claude Code.

## Adding a skill

### 1. Create the skill directory

```bash
mkdir -p skills/my-skill
```

Name it with lowercase letters and hyphens. The directory name becomes the slash command.

### 2. Write SKILL.md

```markdown
---
name: my-skill
description: |
  One clear sentence describing what this skill does and when to use it.
  This text drives auto-invoke matching — be specific.
allowed-tools:
  - Bash
  - Read
triggers:
  - phrase that triggers it
---

## What this skill does

Natural language instructions to Claude. Write like you're briefing a smart colleague.

## Output

\`\`\`
## Result: <topic>

**Finding:** <one sentence>

**Details:**
- ...
\`\`\`
```

### 3. Add a hook (if needed)

If the skill needs to intercept tool calls (warn before destructive commands, enforce scope boundaries), add a hook script:

```bash
mkdir -p skills/my-skill/bin
cat > skills/my-skill/bin/check-my-skill.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c \
  'import sys,json; print(json.loads(sys.stdin.read()).get("tool_input",{}).get("command",""))' \
  2>/dev/null || true)

[ -z "$CMD" ] && echo '{}' && exit 0

# Your check logic here
if printf '%s' "$CMD" | grep -q 'dangerous-pattern'; then
  printf '{"permissionDecision":"ask","message":"[my-skill] Warning: ..."}\\n'
else
  echo '{}'
fi
EOF
chmod +x skills/my-skill/bin/check-my-skill.sh
```

Register the hook in SKILL.md frontmatter:

```yaml
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR}/bin/check-my-skill.sh"
          statusMessage: "Checking..."
```

**Hook script rules:**
- POSIX-portable: use `[[:space:]]` not `\s`, use `^` anchors in sed not `.*pattern`
- Fail safe: return `{}` on error or empty input
- Fast: hooks run before every matching tool call

### 4. Test

```bash
# Install the new skill
./install

# If the skill has a hook, test it directly:
echo '{"tool_input":{"command":"safe command"}}' | bash skills/my-skill/bin/check-my-skill.sh
# Expected: {}

echo '{"tool_input":{"command":"dangerous command"}}' | bash skills/my-skill/bin/check-my-skill.sh
# Expected: {"permissionDecision":"ask","message":"..."}

# Test the full skill in Claude Code:
# Start a new session and invoke /my-skill
```

### 5. Update documentation

- Add a row to the README.md skills table in the appropriate section
- Add an entry to `docs/skills.md` with the full description

### 6. Commit

```bash
git add skills/my-skill/
# Also add README.md and docs/skills.md if updated
git commit -m "feat: add /my-skill — <one sentence description>"
```

## Editing an existing skill

- Read the full SKILL.md before editing. Context matters.
- Touch only what the task requires. Don't "improve" adjacent instructions.
- If you change hook logic, re-run the direct hook tests before committing.
- If you change the `name:` field, re-run `./install` — the directory name must match.

## Skill quality bar

Before submitting:
- [ ] `name:` matches directory name
- [ ] `description:` is one clear sentence
- [ ] `allowed-tools:` contains only tools the skill actually uses
- [ ] Body is prose instructions, not bash
- [ ] If hooks: scripts are POSIX-portable and tested directly
- [ ] Invoked at least once in a real Claude Code session
- [ ] README and docs/skills.md updated
