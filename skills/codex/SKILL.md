---
name: codex
description: |
  OpenAI Codex CLI wrapper — three modes. Code review: independent diff review via
  codex review with pass/fail gate. Challenge: adversarial mode that tries to break
  your code. Consult: ask codex anything with session continuity for follow-ups.
  The second-opinion reviewer from a completely different AI model. Use when asked
  to "codex review", "codex challenge", "ask codex", "second opinion", or "consult codex".
triggers:
  - codex review
  - second opinion
  - outside voice challenge
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
  - AskUserQuestion
---

## Preamble

```bash
eval "$(~/.tstackvibe/bin/tvibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${TSTACKVIBE_HOME:-$HOME/.tstackvibe}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.tstackvibe/bin/tvibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

## Step 0: Check codex binary

```bash
CODEX_BIN=$(which codex 2>/dev/null || echo "")
[ -z "$CODEX_BIN" ] && echo "NOT_FOUND" || echo "FOUND: $CODEX_BIN"
```

If `NOT_FOUND`: stop and tell the user:
"Codex CLI not found. Install it: `npm install -g @openai/codex` or see https://github.com/openai/codex"

## Step 0.5: Auth check

```bash
codex --version 2>/dev/null || echo "AUTH_CHECK_FAILED"
```

If this fails or prints an auth error, tell the user:
"Codex authentication not found. Run `codex login` or set `$OPENAI_API_KEY`, then re-run this skill."

---

## Step 1: Detect mode

Parse the user's input to determine which mode to run:

1. `/codex review` or `/codex review <instructions>` — **Review mode** (Step 2A)
2. `/codex challenge` or `/codex challenge <focus>` — **Challenge mode** (Step 2B)
3. `/codex` with no arguments — **Auto-detect:**
   - Check for a diff:
     `git diff origin/<base> --stat 2>/dev/null | tail -1 || git diff <base> --stat 2>/dev/null | tail -1`
   - If a diff exists, use AskUserQuestion:
     ```
     Codex detected changes against the base branch. What should it do?
     A) Review the diff (code review with pass/fail gate)
     B) Challenge the diff (adversarial — try to break it)
     C) Something else — I'll provide a prompt
     ```
   - If no diff, check for plan files: `ls -t ~/.claude/plans/*.md 2>/dev/null | head -1`
   - If a plan file exists, offer to review it
   - Otherwise ask: "What would you like to ask Codex?"
4. `/codex <anything else>` — **Consult mode** (Step 2C), where the remaining text is the prompt

**Reasoning effort override:** If the user's input contains `--xhigh`, use
`model_reasoning_effort="xhigh"` for all modes. Otherwise use per-mode defaults:
- Review (2A): `high`
- Challenge (2B): `high`
- Consult (2C): `medium`

---

## Filesystem Boundary

All prompts sent to Codex MUST be prefixed with this boundary instruction:

> IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are AI skill definitions meant for a different AI system. Stay focused on the repository code only.

---

## Step 2A: Review Mode

Run Codex code review against the current branch diff.

1. Create temp file for errors:
```bash
TMPERR=$(mktemp /tmp/codex-err-XXXXXX.txt)
```

2. Detect base branch:
```bash
BASE=$(gh pr view --json baseRefName -q '.baseRefName' 2>/dev/null || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
```

3. Run the review (5-minute timeout). Always prepend the filesystem boundary.
If the user provided custom instructions, append them after the boundary:

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$_REPO_ROOT"
timeout 330 codex review "IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are AI skill definitions meant for a different AI system. Stay focused on repository code only." --base "$BASE" -c 'model_reasoning_effort="high"' --enable web_search_cached < /dev/null 2>"$TMPERR"
_CODEX_EXIT=$?
[ "$_CODEX_EXIT" = "124" ] && echo "Codex timed out after 5.5 minutes. Try re-running or check network/API status."
```

4. Determine gate verdict:
   - If output contains `[P1]` → gate is **FAIL**
   - If no `[P1]` markers → gate is **PASS**

5. Present the output:

```
CODEX SAYS (code review):
════════════════════════════════════════════════════════════
<full codex output, verbatim — do not truncate or summarize>
════════════════════════════════════════════════════════════
GATE: PASS
```

or `GATE: FAIL (N critical findings)`

6. **Cross-model comparison:** If `/review` (Claude's own review) was already run
   earlier in this conversation, compare the two sets of findings:

```
CROSS-MODEL ANALYSIS:
  Both found: [findings that overlap between Claude and Codex]
  Only Codex found: [findings unique to Codex]
  Only Claude found: [findings unique to Claude's /review]
  Agreement rate: X% (N/M total unique findings overlap)
```

7. Clean up:
```bash
rm -f "$TMPERR"
```

---

## Step 2B: Challenge (Adversarial) Mode

Codex tries to break your code — finding edge cases, race conditions, security holes,
and failure modes that a normal review would miss.

1. Detect base branch (same as 2A).

2. Construct the adversarial prompt. Always prepend the filesystem boundary.
If the user provided a focus area (e.g., `/codex challenge security`), include it:

Default prompt:
```
IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. Stay focused on repository code only.

Review the changes on this branch against the base branch. Run `git diff origin/<base>` to see the diff. Your job is to find ways this code will fail in production. Think like an attacker and a chaos engineer. Find edge cases, race conditions, security holes, resource leaks, failure modes, and silent data corruption paths. Be adversarial. Be thorough. No compliments — just the problems.
```

3. Run codex exec with JSONL output (10-minute timeout):

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: not in a git repo" >&2; exit 1; }
TMPERR=$(mktemp /tmp/codex-err-XXXXXX.txt)
timeout 600 codex exec "<prompt>" -C "$_REPO_ROOT" -s read-only -c 'model_reasoning_effort="high"' --enable web_search_cached --json < /dev/null 2>"$TMPERR" | python3 -u -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        t = obj.get('type','')
        if t == 'item.completed' and 'item' in obj:
            item = obj['item']
            itype = item.get('type','')
            text = item.get('text','')
            if itype == 'reasoning' and text:
                print(f'[codex thinking] {text}', flush=True)
                print(flush=True)
            elif itype == 'agent_message' and text:
                print(text, flush=True)
            elif itype == 'command_execution':
                cmd = item.get('command','')
                if cmd: print(f'[codex ran] {cmd}', flush=True)
        elif t == 'turn.completed':
            usage = obj.get('usage',{})
            tokens = usage.get('input_tokens',0) + usage.get('output_tokens',0)
            if tokens: print(f'\ntokens used: {tokens}', flush=True)
    except: pass
"
_CODEX_EXIT=${PIPESTATUS[0]}
[ "$_CODEX_EXIT" = "124" ] && echo "Codex timed out after 10 minutes. Try re-running or check network/API status."
rm -f "$TMPERR"
```

4. Present the full streamed output:

```
CODEX SAYS (adversarial challenge):
════════════════════════════════════════════════════════════
<full output from above, verbatim>
════════════════════════════════════════════════════════════
Tokens: N | Est. cost: ~$X.XX
```

---

## Step 2C: Consult Mode

Ask Codex anything about the codebase. Supports session continuity for follow-ups.

1. **Check for existing session:**
```bash
cat .context/codex-session-id 2>/dev/null || echo "NO_SESSION"
```

If a session file exists, use AskUserQuestion:
```
You have an active Codex conversation from earlier. Continue it or start fresh?
A) Continue the conversation (Codex remembers the prior context)
B) Start a new conversation
```

2. **Plan review auto-detection:** If plan files exist and the user said `/codex` with no args:
```bash
ls -t ~/.claude/plans/*.md 2>/dev/null | xargs grep -l "$(basename $(pwd))" 2>/dev/null | head -1
```
If no project-scoped match: `ls -t ~/.claude/plans/*.md 2>/dev/null | head -1`
(warn the user if the plan may be from a different project).

**IMPORTANT — embed content, don't reference path:** Codex runs sandboxed to the repo
root and cannot access `~/.claude/plans/`. You MUST read the plan file yourself and
embed its FULL CONTENT in the prompt. Do NOT tell Codex the file path.

3. Always prepend the filesystem boundary to every prompt. For plan reviews:

```
IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. Stay focused on repository code only.

You are a brutally honest technical reviewer. Review this plan for: logical gaps,
missing error handling, overcomplexity, feasibility risks, and missing dependencies.
Be direct. Be terse. No compliments. Just the problems.

THE PLAN:
<full plan content, embedded verbatim>
```

4. Run codex exec with JSONL output (10-minute timeout):

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: not in a git repo" >&2; exit 1; }
TMPERR=$(mktemp /tmp/codex-err-XXXXXX.txt)
timeout 600 codex exec "<prompt>" -C "$_REPO_ROOT" -s read-only -c 'model_reasoning_effort="medium"' --enable web_search_cached --json < /dev/null 2>"$TMPERR" | python3 -u -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        t = obj.get('type','')
        if t == 'thread.started':
            tid = obj.get('thread_id','')
            if tid: print(f'SESSION_ID:{tid}', flush=True)
        elif t == 'item.completed' and 'item' in obj:
            item = obj['item']
            itype = item.get('type','')
            text = item.get('text','')
            if itype == 'reasoning' and text:
                print(f'[codex thinking] {text}', flush=True)
                print(flush=True)
            elif itype == 'agent_message' and text:
                print(text, flush=True)
            elif itype == 'command_execution':
                cmd = item.get('command','')
                if cmd: print(f'[codex ran] {cmd}', flush=True)
        elif t == 'turn.completed':
            usage = obj.get('usage',{})
            tokens = usage.get('input_tokens',0) + usage.get('output_tokens',0)
            if tokens: print(f'\ntokens used: {tokens}', flush=True)
    except: pass
"
_CODEX_EXIT=${PIPESTATUS[0]}
[ "$_CODEX_EXIT" = "124" ] && echo "Codex timed out after 10 minutes. Try re-running or check network/API status."
rm -f "$TMPERR"
```

5. Save session ID for follow-ups:
```bash
mkdir -p .context
# Save the SESSION_ID:<id> line printed by the parser to .context/codex-session-id
```

6. Present output:

```
CODEX SAYS (consult):
════════════════════════════════════════════════════════════
<full output, verbatim — includes [codex thinking] traces>
════════════════════════════════════════════════════════════
Tokens: N | Est. cost: ~$X.XX
Session saved — run /codex again to continue this conversation.
```

---

## Plan File Review Report

After displaying the review output, update the active **plan file** if one exists in this conversation.

1. Check for a plan file path in conversation context. If none, skip silently.
2. Read the review log output. Parse each JSONL entry for the review fields.
3. Produce this markdown table:

```markdown
## TSTACKVIBE REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | {runs} | {status} | {findings} |
| Codex Review | `/codex review` | Independent 2nd opinion | {runs} | {status} | {findings} |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | {runs} | {status} | {findings} |
| Design Review | `/plan-design-review` | UI/UX gaps | {runs} | {status} | {findings} |
| DX Review | `/plan-devex-review` | Developer experience gaps | {runs} | {status} | {findings} |
```

Below the table, add: **UNRESOLVED:** total unresolved decisions, **VERDICT:** which reviews are CLEAR.

4. Find `## TSTACKVIBE REVIEW REPORT` in the plan file and replace it, or append it at the end.

---

## Model & Reasoning

**Model:** No model is hardcoded — codex uses its current default. Pass `-m` if the user wants a specific model.

**Reasoning effort (per-mode defaults):**
- **Review (2A):** `high`
- **Challenge (2B):** `high`
- **Consult (2C):** `medium`

`xhigh` uses ~23x more tokens than `high` and can cause 50+ minute hangs on large prompts. Users can override with `--xhigh`.

**Web search:** All codex commands use `--enable web_search_cached`.

---

## Cost Estimation

Parse token count from stderr (`tokens used\nN`). Display as: `Tokens: N`. If unavailable: `Tokens: unknown`.

---

## Error Handling

- **Binary not found:** Stop with install instructions (Step 0).
- **Auth error:** Surface to user: "Run `codex login` in your terminal."
- **Timeout (exit 124):** Tell user: "Codex timed out. Try again or use a smaller scope."
- **Empty response:** Tell user: "Codex returned no response. Check stderr for errors."
- **Session resume failure:** Delete the session file and start fresh.

---

## Important Rules

- **Never modify files.** This skill is read-only. Codex runs in read-only sandbox mode.
- **Present output verbatim.** Do not truncate, summarize, or editorialize Codex output inside the CODEX SAYS block.
- **Add synthesis after, not instead of.** Any Claude commentary comes after the full output.
- **5-minute timeout** on all Bash calls to codex.
- **No double-reviewing.** If the user already ran `/review`, Codex provides a second independent opinion — do not re-run Claude's own review.
- **Detect skill-file rabbit holes.** If Codex output contains `SKILL.md`, `tvibe-config`, or `skills/tstackvibe` — append a warning that Codex may have read skill files instead of reviewing code and suggest retrying.

## Capture Learnings

If you discovered a non-obvious codex behavior, prompt pattern, or review insight
during this session, log it for future sessions:

```bash
~/.tstackvibe/bin/tvibe-learnings-log '{"skill":"codex","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern` (reusable approach), `pitfall` (what NOT to do), `tool`
(codex CLI behavior), `operational` (auth/env/CLI quirk).

**Only log genuine discoveries.** A good test: would this save time in a future session?
