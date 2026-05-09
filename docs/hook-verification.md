# Hook Verification — Manual Procedure

**Audience:** anyone who installs vibestack into Cursor or Kiro and uses the
hook-bearing skills (`careful`, `freeze`, `guard`, `investigate`).

**Why this exists.** The Agent Skills open standard (agentskills.io) standardizes
the SKILL.md file shape. It does **not** standardize per-skill `PreToolUse` hooks,
the `${CLAUDE_SKILL_DIR}` env var, or any of Claude Code's other runtime
extensions. vibestack's safety skills depend on those Claude-Code-specific
features. When you install into Cursor or Kiro, the SKILL.md file lands at the
right path, but whether the hook actually fires is **agent-specific runtime
behavior** that can only be verified empirically.

This document gives you a reproducible 5-minute procedure to verify, per target,
whether each hook-bearing skill actually intercepts the corresponding dangerous
command. Run it once after each `./install --target=cursor` or
`--target=kiro`. Re-run after each major Cursor / Kiro version upgrade —
runtime behavior can change.

## What "verified" means

For each (target × skill) pair, you'll run a deliberate dangerous command and
observe whether the skill's hook fires:

- **PASS (hard tier)**: hook intercepts the command and prompts you (or blocks
  outright). Behavior matches Claude Code exactly. The skill is hard-enforced
  in this target.
- **FAIL (soft tier)**: hook does NOT fire; the command runs unimpeded. The
  skill installed but its safety guarantee degrades to "the LLM might decide
  to warn you in chat" — non-deterministic, instruction-following only.
- **INCONCLUSIVE**: ambiguous — for example, hook fires but the message format
  differs from Claude Code's. Note the difference; treat as soft tier until
  re-verified.

## Procedure (per target × skill)

### 0. Prerequisites
- vibestack installed into the target (e.g., `./install --target=cursor`)
- Target agent (Cursor or Kiro) running, with vibestack skills visible in its
  skill list
- A throwaway directory: `mkdir -p /tmp/vibestack-hook-test && cd /tmp/vibestack-hook-test`

### Test 1 — `/careful` (destructive command interception)

1. In the target agent, open a session in `/tmp/vibestack-hook-test`.
2. Activate careful mode by typing `/careful`.
3. Ask the agent to run: `rm -rf /tmp/vibestack-hook-test/*`
4. **Observe:**
   - **PASS** if the agent pauses, displays the command, and asks for explicit
     confirmation BEFORE running it (this is the `careful` hook firing via
     PreToolUse interception).
   - **FAIL** if the agent runs the command immediately without prompting.
   - **INCONCLUSIVE** if the agent prompts but in a different format from
     Claude Code (e.g., a generic confirm dialog instead of careful's
     specific message).

### Test 2 — `/freeze` (edit-outside-boundary interception)

1. In the target agent, in `/tmp/vibestack-hook-test`, create a file:
   `echo "test" > inside.txt`
2. Activate freeze mode at this directory: type `/freeze` (the skill should
   record this directory as the boundary).
3. Ask the agent to edit a file OUTSIDE that boundary:
   `Edit ~/.zshrc` (or any file outside `/tmp/vibestack-hook-test`).
4. **Observe:**
   - **PASS** if the agent refuses or asks for confirmation BEFORE the edit
     happens (freeze's hook firing).
   - **FAIL** if the agent edits the file with no friction.
   - **INCONCLUSIVE** if behavior differs from Claude Code.

### Test 3 — `/guard` (uses careful's hook script via cross-skill path)

If careful's Test 1 passed, also verify guard:

1. Activate `/guard` in the target.
2. Try the same `rm -rf /tmp/vibestack-hook-test/*` command.
3. **Observe:** PASS if guard fires the same way careful did. FAIL if guard
   doesn't fire even though careful did — this means the cross-skill
   `${CLAUDE_SKILL_DIR}/../careful/bin/check-careful.sh` path didn't resolve.

### Test 4 — `/investigate` (uses freeze's hook script via cross-skill path)

If freeze's Test 2 passed, also verify investigate:

1. Activate `/investigate` in the target.
2. Try editing a file outside the investigation boundary.
3. **Observe:** PASS if investigate fires like freeze did. FAIL otherwise.

## Recording results

Use this matrix per target. Paste your results into your team's docs (or a
GitHub issue if you'd like vibestack to track community verification):

```
Target: <cursor | kiro>
Tested on: <date>
Target version: <agent version>

| Skill        | Test           | Result (PASS/FAIL/INCONCLUSIVE) | Notes |
|--------------|----------------|----------------------------------|-------|
| careful      | rm -rf intercept | _________                      | _____ |
| freeze       | edit-outside intercept | _________                | _____ |
| guard        | (depends on careful) | _________                  | _____ |
| investigate  | (depends on freeze)  | _________                  | _____ |
```

If all 4 PASS → hook tier is **hard** in this target. The README's compatibility
disclosure can be updated to reflect parity with Claude Code.

If any FAIL → hook tier is **soft** in this target. The README's conservative
disclosure stays accurate; users should know to double-check destructive
commands manually.

## Troubleshooting

**Hook doesn't fire in Cursor:**
- Check that `~/.cursor/skills/<skill>/bin/check-*.sh` exists (may be a symlink
  to the cloned repo's `skills/<n>/bin/`).
- Check that Cursor recognizes `hooks:` in frontmatter — Cursor docs may
  silently ignore unknown fields.
- Try restarting Cursor — some agents only re-scan skills on startup.

**Hook doesn't fire in Kiro:**
- Check Kiro's hook documentation: kiro.dev/docs/cli/hooks/
- Kiro's hook config schema may differ from Claude Code's PreToolUse
  format. If Kiro requires a different field name (e.g., `preToolUse:`
  instead of `hooks: PreToolUse:`), file a vibestack issue — a
  per-target frontmatter rewrite would be needed in v1.5+.

**`${CLAUDE_SKILL_DIR}` substitution failing:**
- This is the most likely failure mode. Cursor and Kiro may use different
  env var names, or none at all.
- The hook script command will literally try to `bash ${CLAUDE_SKILL_DIR}/...`
  and fail with "no such file or directory."
- If this is the failure mode, file an issue. The fix is either a per-target
  env var shim in install (track as v1.5 candidate `vibe certify` /
  `vibe-hook-shim`) or a per-target frontmatter rewrite.

## What we did NOT verify in v1.4.0

- Behavior under non-default Cursor/Kiro security profiles
- Behavior with Cursor's `--auto-run` flag enabled
- Behavior under Kiro's "approve all" mode
- Cross-target hook script execution (e.g., guard's reference to careful's
  script when only one of the two is installed)

These edge cases land in v1.5+ as user demand emerges.
