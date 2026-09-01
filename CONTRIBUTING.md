# Contributing


## Naming

Everything here is published under this project's own name. Write about what the
code does, not where a behavior came from — in files, and equally in commit
messages, PR text and release notes.

```bash
bin/vibe-brand-audit --commits main..HEAD
```

CI runs this on every PR. It is checked before a merge on purpose: a merged
commit message cannot be corrected without rewriting published history.

## Setup

```bash
git clone https://github.com/timurgaleev/vibestack
cd vibestack
./install
```

No other dependencies. vibestack requires only Bash and at least one
[Agent Skills standard](https://agentskills.io/specification) host —
Claude Code, Cursor, or Kiro. The install asks per target.

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

Natural language instructions to the host agent. Write like you're briefing a smart colleague.

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

# Shared JSON helpers: a real parser plus a safe decision encoder.
# Never extract with grep (it truncates at the first escaped quote) and never
# hand-build the decision JSON (a quote in the message discards the decision).
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HOOK_HELPER="$_HOOK_DIR/../../careful/bin/hook-extract.sh"
if [ ! -f "$_HOOK_HELPER" ] || ! . "$_HOOK_HELPER" 2>/dev/null; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"[my-skill] Hook helpers unavailable."}}\\n'
  exit 0
fi

set +e
CMD=$(vibe_hook_extract_field "$INPUT" command)
EXTRACT_RC=$?
set -e

# Unreadable payload: pick a polarity on purpose. Ask-tier asks; a boundary denies.
# Empty stdin counts as unreadable — a PreToolUse call always carries a payload,
# so nothing on stdin means something upstream broke. Do NOT add a `-n "$INPUT"`
# guard here: it turns the fail-closed branch into an allow.
if [ "$EXTRACT_RC" -ne 0 ]; then
  vibe_hook_decision ask "[my-skill] Could not parse the tool payload."
  exit 0
fi

[ -z "$CMD" ] && echo '{}' && exit 0

# Your check logic here
if printf '%s' "$CMD" | grep -q 'dangerous-pattern'; then
  vibe_hook_decision ask "[my-skill] Warning: ..."
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
- Emit decisions through `vibe_hook_decision` — the payload must be nested under
  `hookSpecificOutput`, because Claude Code ignores a top-level `permissionDecision`
  and the resulting no-op is silent
- Fail safe, not fail open: `{}` is the *allow* answer, so never return it for an
  error you did not understand. Ask-tier hooks ask; boundary hooks deny
- Fast: hooks run before every matching tool call

### 4. Test

```bash
# Install the new skill
./install

# If the skill has a hook, test it directly:
echo '{"tool_input":{"command":"safe command"}}' | bash skills/my-skill/bin/check-my-skill.sh
# Expected: {}

echo '{"tool_input":{"command":"dangerous command"}}' | bash skills/my-skill/bin/check-my-skill.sh
# Expected: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"..."}}

echo 'not json' | bash skills/my-skill/bin/check-my-skill.sh
# Expected: a decision, never {} — an unreadable payload must not be an allow

# Test the full skill in your agent (Claude Code, Cursor, or Kiro):
# Start a new session and invoke /my-skill
# For hook-bearing skills, see docs/hook-verification.md to confirm
# the hook actually fires in non-Claude targets.
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
- If you change hook logic, run `bash test/test-hooks.sh` before committing — it asserts the
  decision wire format and both fail-closed polarities, not just the verdict.
- CI runs every suite in `test/` on Linux and macOS for each PR. Run the one you touched
  locally first; `docs/internals.md` lists what each suite covers.
- If you change the `name:` field, re-run `./install` — the directory name must match.

## Skill quality bar

Before submitting:
- [ ] `name:` matches directory name
- [ ] `description:` is one clear sentence
- [ ] `allowed-tools:` contains only tools the skill actually uses
- [ ] Body is prose instructions, not bash
- [ ] If hooks: scripts are POSIX-portable and tested directly
- [ ] Invoked at least once in a real agent session (Claude Code, Cursor, or Kiro)
- [ ] If hook-bearing: hook tier documented in `docs/agent-skills-compatibility-audit.md`
- [ ] README and docs/skills.md updated
