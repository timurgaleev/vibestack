---
name: claude
description: |
  Independent second opinion from the Claude Code CLI: review a diff, challenge it adversarially, or consult.
triggers:
  - claude review
  - claude challenge
  - ask claude
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

## When to invoke

Use when asked for "claude review", "claude challenge", "ask claude", "second opinion from claude", or "outside voice".

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

# /claude - Claude Outside Voice

This skill wraps `claude --print` to get an independent Claude Code second opinion
without allowing nested Claude to modify files.

The generated external invocation name is `vibe-claude`.

---

## Step 0: Check Claude CLI

```bash
CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "")
[ -z "$CLAUDE_BIN" ] && echo "NOT_FOUND" || echo "FOUND: $CLAUDE_BIN"
```

If `NOT_FOUND`, stop and tell the user:
"Claude CLI not found. Install Claude Code, then re-run this skill."

Do not infer authentication state from credential files or environment
variables, and do not gate on them. Claude Code may hold its credentials in an
OS keychain that is invisible from inside the host agent's sandbox, so a
file-existence check reports a blocker on a perfectly authenticated machine and
the skill refuses to run at all. Only report an authentication problem when the
actual `claude --print` invocation below returns an auth, login, or unauthorized
error.

Resolve the binary and invoke it in the same host execution context — do not
resolve it inside a sandbox and then run a different `claude` from another PATH.

**Running-under-Claude-Code probe.** A live Claude Code session exports
`CLAUDECODE` into every shell it spawns, so this block can tell that the host IS
Claude Code. A nested run there is the same model with a fresh context — useful
for a cold read, but not a cross-model opinion, and it costs a full session.

```bash
if [ -n "${CLAUDECODE:-}" ] && [ "${VIBE_FORCE_CLAUDE_REVIEW:-0}" != "1" ]; then
  echo "HOST: claude"
fi
```

If `HOST: claude`:

- **`SESSION_KIND: interactive`** — ask with AskUserQuestion: "You are already in
  Claude Code — /claude gives a fresh-context opinion from the same model, not a
  cross-model one." Options: **A) Run /codex instead** (recommended when installed),
  **B) Run anyway**, **C) Stop**. Only an explicit B continues this skill. A stops
  here and runs `/codex` with the same mode and arguments; C stops.
- **`SESSION_KIND: spawned` or `headless`** — print "Warning: running under Claude
  Code — this is a same-model, fresh-context opinion, not a cross-model one." and
  continue.

`VIBE_FORCE_CLAUDE_REVIEW=1` skips the probe and the question.

---

## Step 0.7: Base branch

Review and Challenge diff against the base branch. Resolve it once here: the PR's
base, then the repo default, then `origin/HEAD`, then `main`, then `master`.

```bash
BASE_BRANCH=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null) || BASE_BRANCH=""
[ -n "$BASE_BRANCH" ] || BASE_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) || BASE_BRANCH=""
if [ -z "$BASE_BRANCH" ]; then
  # Capture first: in a pipeline the status is the last command's, so a
  # `|| fallback` after `| sed` never fires when origin/HEAD is unset.
  _ORIGIN_HEAD=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) && BASE_BRANCH=${_ORIGIN_HEAD#refs/remotes/origin/}
fi
[ -n "$BASE_BRANCH" ] || { git rev-parse --verify --quiet origin/main >/dev/null && BASE_BRANCH=main; }
[ -n "$BASE_BRANCH" ] || { { git rev-parse --verify --quiet origin/master >/dev/null || git rev-parse --verify --quiet master >/dev/null; } && BASE_BRANCH=master; }
echo "BASE_BRANCH: $BASE_BRANCH"
[ -n "$BASE_BRANCH" ] || echo "BASE_BRANCH_UNRESOLVED"
```

If `BASE_BRANCH_UNRESOLVED`, ask the user which branch to diff against. Every later
block that diffs starts with `BASE_BRANCH='<BASE_BRANCH>'`: replace the placeholder
with the name printed above.

---

## Safety Boundary

Nested Claude must stay focused on the user's repository and must not run
vibestack skills from inside this skill.

Every nested `claude --print` call MUST include:

- `--disable-slash-commands`
- `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` — start no MCP server, not even the user's configured ones
- `--settings '{"disableAllHooks":true}'` — run none of the user's hooks
- `--disallowedTools 'mcp__*'` — no MCP tool, whatever the user's allowlist grants
- Review/challenge: `--tools ""`
- Consult: `--allowedTools Read,Grep,Glob --disallowedTools 'Bash,Edit,Write,mcp__*'`

Never pass `Bash`, `Edit`, or `Write` to nested Claude in this skill.

All prompts MUST be written to a temp file and fed through stdin. Never interpolate
user text directly into the shell command — not into a quoted argument, and not into
a heredoc either: a line of user text equal to the terminator ends the heredoc and
everything after it runs as shell. User text reaches the prompt only through
`USER_TEXT_FILE`, which you fill with the Write tool.

---

## Step 1: Detect Mode

Parse the user's input:

1. `/claude review` or `/claude review <instructions>` - **Review mode** (Step 2A)
2. `/claude challenge` or `/claude challenge <focus>` - **Challenge mode** (Step 2B)
3. `/claude` with no arguments, or `/claude <anything else>` - **Consult mode** (Step 2C)

If no mode is obvious and a diff exists, ask whether to review, challenge, or consult.

---

## Shared Helpers

Use these shell snippets in every mode.

Create temp files:

```bash
PROMPT_FILE=$(mktemp /tmp/vibe-claude-prompt-XXXXXX)
RESP_FILE=$(mktemp /tmp/vibe-claude-response-XXXXXX.json)
ERR_FILE=$(mktemp /tmp/vibe-claude-error-XXXXXX.txt)
USER_TEXT_FILE=$(mktemp /tmp/vibe-claude-user-XXXXXX)
echo "PROMPT_FILE: $PROMPT_FILE"
echo "RESP_FILE: $RESP_FILE"
echo "ERR_FILE: $ERR_FILE"
echo "USER_TEXT_FILE: $USER_TEXT_FILE"
```

Each Bash call starts a fresh shell, so every later block opens with assignments such
as `PROMPT_FILE='<PROMPT_FILE>'`: replace each placeholder with the path this block
printed (and `<DIFF_FILE>` with the path the diff block prints).

`mktemp` creates each file readable by you alone. The user's instructions, focus
area or question go into the printed `USER_TEXT_FILE` — **Read the empty file, then
Write the user's text into it verbatim with the Write tool.** Leave it empty when
the user gave none (review and challenge only; consult always has a question).

Cleanup at the end of every mode:

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
USER_TEXT_FILE='<USER_TEXT_FILE>'
rm -f "$PROMPT_FILE" "$RESP_FILE" "$ERR_FILE" "$USER_TEXT_FILE"
```

Parse and grade the JSON output. Set `CLAUDE_MODE` to `review`, `challenge` or
`consult`. The parser is fail-closed: anything short of a completed, non-empty
answer is `unavailable` (exit 1), never a review that found nothing.

```bash
RESP_FILE='<RESP_FILE>'
CLAUDE_MODE='<review|challenge|consult>'
python3 - "$RESP_FILE" "$CLAUDE_MODE" <<'VIBE_CLAUDE_PARSE_PY'
import json, os, re, sys

CAP = 33554432  # the run block's `head -c` cap: a file this size was cut off
path, mode = sys.argv[1], sys.argv[2]
if mode not in ("review", "challenge", "consult"):
    print(f"CLAUDE_STATUS: unavailable (unknown mode {mode!r})")
    sys.exit(1)

def unavailable(reason):
    print(f"CLAUDE_STATUS: unavailable ({reason})")
    if mode != "consult":
        print(f"GATE: FAIL (review unavailable — {reason})")
    sys.exit(1)

try:
    size = os.path.getsize(path)
except OSError as exc:
    unavailable(f"no response file: {exc}")
if size == 0:
    unavailable("empty response")
if size >= CAP:
    unavailable("output truncated at 32 MiB")
try:
    with open(path) as fh:
        obj = json.load(fh)
except Exception as exc:
    unavailable(f"JSON parse error: {exc}")
if not isinstance(obj, dict):
    unavailable("response is not a JSON object")
if obj.get("is_error"):
    unavailable(f"is_error: {str(obj.get('result') or obj.get('subtype') or 'no message')[:200]}")
if obj.get("subtype") != "success":
    unavailable(f"subtype={obj.get('subtype')!r}")
result = obj.get("result")
if not isinstance(result, str) or not result.strip():
    unavailable("missing or empty result")

print(result)

usage = obj.get("usage") or {}
input_tokens = usage.get("input_tokens", 0) or 0
output_tokens = usage.get("output_tokens", 0) or 0
cache_read = usage.get("cache_read_input_tokens", 0) or 0
model = obj.get("model") or "unknown"
session_id = obj.get("session_id") or ""

def footer():
    print(f"\nTokens: input={input_tokens} output={output_tokens} cache_read={cache_read} | Model: {model}")
    if session_id:
        print(f"SESSION_ID:{session_id}")

if mode == "consult":
    print("\nCLAUDE_STATUS: answered")
    footer()
    sys.exit(0)

counts = {p: len(re.findall(r"\[P%s\]" % p, result)) for p in "123"}
total = sum(counts.values())
no_findings = re.search(r"(?m)^[\s`*]*NO_FINDINGS[\s`*]*$", result) is not None
print(f"\nFINDINGS: {total}")
if counts["1"]:
    print(f"GATE: FAIL ({counts['1']} critical findings)")
    code = 3
elif total:
    print(f"GATE: PASS (P2={counts['2']} P3={counts['3']})")
    code = 0
elif no_findings:
    print("GATE: PASS")
    code = 0
else:
    print("GATE: UNVERIFIED (Claude tagged nothing; read the output above)")
    code = 4
footer()
sys.exit(code)
VIBE_CLAUDE_PARSE_PY
```

Exit 0 is `GATE: PASS` (or a consult `answered`), 3 is `GATE: FAIL`, 4 is
`GATE: UNVERIFIED`, and 1 is `CLAUDE_STATUS: unavailable`. PASS is reachable only
through `[P2]`/`[P3]` tags with no `[P1]`, or an explicit `NO_FINDINGS` line —
never from untagged prose, however clean it reads.

If stderr contains `auth`, `login`, or `unauthorized`, tell the user:
"Claude authentication failed. Run `claude` interactively to authenticate or export `ANTHROPIC_API_KEY`."

---

## Step 2A: Review Mode

Review the current branch diff with nested Claude in tool-less mode.

1. Fetch base and capture diff:

```bash
BASE_BRANCH='<BASE_BRANCH>'
[ -n "$BASE_BRANCH" ] || { echo "BASE_BRANCH_UNRESOLVED"; exit 1; }
_REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$_REPO_ROOT"
DIFF_FILE=$(mktemp /tmp/vibe-claude-diff-XXXXXX.patch)
git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true
git diff "origin/$BASE_BRANCH" > "$DIFF_FILE" 2>/dev/null || git diff "$BASE_BRANCH" > "$DIFF_FILE"
echo "DIFF_FILE: $DIFF_FILE"
```

If the diff file is empty, stop and say:
"Nothing to review - no changes against the base branch."

2. Write any custom review instructions the user gave into `USER_TEXT_FILE` with the
   Write tool (see Shared Helpers), then assemble the prompt file:

```bash
PROMPT_FILE='<PROMPT_FILE>'
USER_TEXT_FILE='<USER_TEXT_FILE>'
DIFF_FILE='<DIFF_FILE>'
{
  cat <<'EOF'
You are a brutally honest Claude Code reviewer. Review this git diff for bugs,
production failure modes, security issues, missing tests, and maintainability
problems. Be direct. No compliments. Reference files and changed code where possible.

Start every finding with a severity tag: [P1] for a must-fix before merge (a bug,
data loss, a security hole), [P2] for a should-fix, [P3] for a minor issue. If you
find nothing worth reporting, reply with the single line NO_FINDINGS.

Additional user instructions, if any:
EOF
  cat "$USER_TEXT_FILE"
  printf '\nDIFF:\n'
  cat "$DIFF_FILE"
} > "$PROMPT_FILE"
```

3. Run Claude:

Pass `timeout: 600000` on this Bash call. The 540-second wrapper sits below that
10-minute gate so a stall surfaces as exit 124 with a message, never as a silent
harness kill that leaves an empty response to be read as "nothing found".

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
# Portable timeout: gtimeout → timeout → a polling watchdog. Stock macOS ships
# neither binary; the watchdog returns 124 on overrun, as timeout(1) does.
_CL_TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)
# A function, not an inline ${VAR:+...} prefix: zsh does not word-split that
# expansion, so "gtimeout 540" would reach execve as one argument (exit 127).
_cl() {
  if [ -n "${_CL_TO:-}" ]; then "$_CL_TO" "$@"; return; fi
  _cl_s=$1; shift
  "$@" <&0 & _cl_p=$!
  while kill -0 "$_cl_p" 2>/dev/null; do
    if [ "$_cl_s" -le 0 ]; then
      pkill -TERM -P "$_cl_p" 2>/dev/null; kill -TERM "$_cl_p" 2>/dev/null; sleep 2
      pkill -KILL -P "$_cl_p" 2>/dev/null; kill -KILL "$_cl_p" 2>/dev/null
      wait "$_cl_p" 2>/dev/null; return 124
    fi
    sleep 1; _cl_s=$((_cl_s - 1))
  done
  wait "$_cl_p"
}
_cl 540 claude -p --output-format json --disable-slash-commands --strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings '{"disableAllHooks":true}' --tools "" --disallowedTools 'mcp__*' < "$PROMPT_FILE" 2>"$ERR_FILE" | head -c 33554432 > "$RESP_FILE"
_CL_EXIT=${PIPESTATUS[0]:-${pipestatus[1]}}
if [ "$_CL_EXIT" = "124" ]; then
  "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log" '{"skill":"claude-review","status":"timeout","gate":"fail","completed":false,"timeout_s":540}' >/dev/null 2>&1 || true
  echo "Claude stalled past 9 minutes. Common causes: model API stall, a long prompt, a network issue. Re-run; if it persists, split the diff or the question."
  echo "CLAUDE_RESULT: TIMEOUT"
elif [ "$_CL_EXIT" != "0" ]; then
  echo "[claude exit $_CL_EXIT] $(head -n1 "$ERR_FILE" 2>/dev/null)"
  echo "CLAUDE_RESULT: FAILED (exit $_CL_EXIT)"
else
  echo "CLAUDE_RESULT: OK"
fi
if grep -qiE "auth|login|unauthorized" "$ERR_FILE" 2>/dev/null; then
  echo "[claude auth error] $(head -n1 "$ERR_FILE")"
fi
```

4. Grade and present the output. Run the parser from Shared Helpers with
   `CLAUDE_MODE='review'` — unless the run block printed `CLAUDE_RESULT: TIMEOUT`:
   that run is already logged, so skip the parser and the log step and report
   `GATE: FAIL (review unavailable — timeout)`. A `CLAUDE_RESULT: FAILED` line
   makes the run unavailable whatever the parser prints.

```
CLAUDE SAYS (code review):
============================================================
<parsed result from RESP_FILE, verbatim>
============================================================
GATE: PASS | GATE: FAIL (N critical findings) | GATE: UNVERIFIED (...) | GATE: FAIL (review unavailable — <reason>)
```

   Never report a clean review when the run was unavailable or timed out, and never
   turn `GATE: UNVERIFIED` into a pass — tell the user to read the output and decide.

   Then emit ONE recommendation line:

```
Recommendation: <action> because <one-line reason that names the most actionable finding>
```

   The reason must engage with a specific finding, or compare against an
   alternative (another finding, fix-vs-ship, fix order). Boilerplate ("because
   Claude found things") fails the format. On an unavailable run, recommend the
   re-run or the other reviewer, and say why.

5. Log the result, unless step 4 skipped it for a timeout:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log" '{"skill":"claude-review","status":"STATUS","gate":"GATE","findings":N,"completed":COMPLETED,"commit":"'"$(git rev-parse --short HEAD)"'"}' >/dev/null 2>&1 || true
```

   Substitute STATUS — `pass` on `GATE: PASS`, `findings` on `GATE: FAIL (N critical
   findings)`, `unverified` on `GATE: UNVERIFIED`, `unavailable` on
   `CLAUDE_STATUS: unavailable` or `CLAUDE_RESULT: FAILED`; GATE — `pass`, `fail` or
   `unverified` (`fail` when unavailable); N — the `FINDINGS:` count, 0 when
   unavailable; COMPLETED — `true` when the parser graded a completed run, `false`
   when it was unavailable.

6. Cleanup:

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
USER_TEXT_FILE='<USER_TEXT_FILE>'
DIFF_FILE='<DIFF_FILE>'
rm -f "$DIFF_FILE" "$PROMPT_FILE" "$RESP_FILE" "$ERR_FILE" "$USER_TEXT_FILE"
```

---

## Step 2B: Challenge Mode

Run an adversarial failure-mode review with nested Claude in tool-less mode.

1. Capture the diff using the same diff commands from Review mode.

2. Write the focus area the user gave, if any, into `USER_TEXT_FILE` with the Write
   tool (see Shared Helpers), then assemble the prompt:

```bash
PROMPT_FILE='<PROMPT_FILE>'
USER_TEXT_FILE='<USER_TEXT_FILE>'
DIFF_FILE='<DIFF_FILE>'
{
  cat <<'EOF'
You are an adversarial Claude Code reviewer. Try to break this change before users do.
Find edge cases, race conditions, security holes, resource leaks, silent data
corruption, bad error handling, and operational failure modes. Be thorough. No
compliments. If the user provided a focus area, prioritize it.

Start every finding with a severity tag: [P1] for a must-fix before merge (a bug,
data loss, a security hole), [P2] for a should-fix, [P3] for a minor issue. If you
find nothing worth reporting, reply with the single line NO_FINDINGS.

Focus area, if any:
EOF
  cat "$USER_TEXT_FILE"
  printf '\nDIFF:\n'
  cat "$DIFF_FILE"
} > "$PROMPT_FILE"
```

3. Run Claude:

Pass `timeout: 600000` on this Bash call. The 540-second wrapper sits below that
10-minute gate so a stall surfaces as exit 124 with a message, never as a silent
harness kill that leaves an empty response to be read as "nothing found".

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
# Portable timeout: gtimeout → timeout → a polling watchdog. Stock macOS ships
# neither binary; the watchdog returns 124 on overrun, as timeout(1) does.
_CL_TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)
# A function, not an inline ${VAR:+...} prefix: zsh does not word-split that
# expansion, so "gtimeout 540" would reach execve as one argument (exit 127).
_cl() {
  if [ -n "${_CL_TO:-}" ]; then "$_CL_TO" "$@"; return; fi
  _cl_s=$1; shift
  "$@" <&0 & _cl_p=$!
  while kill -0 "$_cl_p" 2>/dev/null; do
    if [ "$_cl_s" -le 0 ]; then
      pkill -TERM -P "$_cl_p" 2>/dev/null; kill -TERM "$_cl_p" 2>/dev/null; sleep 2
      pkill -KILL -P "$_cl_p" 2>/dev/null; kill -KILL "$_cl_p" 2>/dev/null
      wait "$_cl_p" 2>/dev/null; return 124
    fi
    sleep 1; _cl_s=$((_cl_s - 1))
  done
  wait "$_cl_p"
}
_cl 540 claude -p --output-format json --disable-slash-commands --strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings '{"disableAllHooks":true}' --tools "" --disallowedTools 'mcp__*' < "$PROMPT_FILE" 2>"$ERR_FILE" | head -c 33554432 > "$RESP_FILE"
_CL_EXIT=${PIPESTATUS[0]:-${pipestatus[1]}}
if [ "$_CL_EXIT" = "124" ]; then
  "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log" '{"skill":"claude-challenge","status":"timeout","gate":"fail","completed":false,"timeout_s":540}' >/dev/null 2>&1 || true
  echo "Claude stalled past 9 minutes. Common causes: model API stall, a long prompt, a network issue. Re-run; if it persists, split the diff or the question."
  echo "CLAUDE_RESULT: TIMEOUT"
elif [ "$_CL_EXIT" != "0" ]; then
  echo "[claude exit $_CL_EXIT] $(head -n1 "$ERR_FILE" 2>/dev/null)"
  echo "CLAUDE_RESULT: FAILED (exit $_CL_EXIT)"
else
  echo "CLAUDE_RESULT: OK"
fi
if grep -qiE "auth|login|unauthorized" "$ERR_FILE" 2>/dev/null; then
  echo "[claude auth error] $(head -n1 "$ERR_FILE")"
fi
```

4. Grade and present the output. Run the parser from Shared Helpers with
   `CLAUDE_MODE='challenge'` — unless the run block printed `CLAUDE_RESULT: TIMEOUT`:
   that run is already logged, so skip the parser and the log step and report
   `GATE: FAIL (review unavailable — timeout)`. A `CLAUDE_RESULT: FAILED` line
   makes the run unavailable whatever the parser prints.

```
CLAUDE SAYS (adversarial challenge):
============================================================
<parsed result from RESP_FILE, verbatim>
============================================================
GATE: PASS | GATE: FAIL (N critical findings) | GATE: UNVERIFIED (...) | GATE: FAIL (review unavailable — <reason>)
```

   Never report a clean challenge when the run was unavailable or timed out, and never
   turn `GATE: UNVERIFIED` into a pass — tell the user to read the output and decide.

   Then emit ONE recommendation line:

```
Recommendation: <action> because <one-line reason that names the most actionable finding>
```

   The reason must engage with a specific finding, or compare against an
   alternative (another finding, fix-vs-ship, fix order). Boilerplate ("because
   Claude found things") fails the format. On an unavailable run, recommend the
   re-run or the other reviewer, and say why.

5. Log the result, unless step 4 skipped it for a timeout:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log" '{"skill":"claude-challenge","status":"STATUS","gate":"GATE","findings":N,"completed":COMPLETED,"commit":"'"$(git rev-parse --short HEAD)"'"}' >/dev/null 2>&1 || true
```

   Substitute STATUS — `pass` on `GATE: PASS`, `findings` on `GATE: FAIL (N critical
   findings)`, `unverified` on `GATE: UNVERIFIED`, `unavailable` on
   `CLAUDE_STATUS: unavailable` or `CLAUDE_RESULT: FAILED`; GATE — `pass`, `fail` or
   `unverified` (`fail` when unavailable); N — the `FINDINGS:` count, 0 when
   unavailable; COMPLETED — `true` when the parser graded a completed run, `false`
   when it was unavailable.

6. Cleanup:

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
USER_TEXT_FILE='<USER_TEXT_FILE>'
DIFF_FILE='<DIFF_FILE>'
rm -f "$DIFF_FILE" "$PROMPT_FILE" "$RESP_FILE" "$ERR_FILE" "$USER_TEXT_FILE"
```

---

## Step 2C: Consult Mode

Ask Claude about the repository. Consult mode may inspect files, but only with
read-only tools.

1. Check for an existing Claude session:

```bash
cat .context/claude-session-id 2>/dev/null || echo "NO_SESSION"
```

If a session exists, ask the user whether to continue it or start fresh.

2. Write the user's question into `USER_TEXT_FILE` with the Write tool (see Shared
   Helpers), then assemble the prompt:

```bash
PROMPT_FILE='<PROMPT_FILE>'
USER_TEXT_FILE='<USER_TEXT_FILE>'
[ -s "$USER_TEXT_FILE" ] || { echo "QUESTION_MISSING: write the question into $USER_TEXT_FILE with the Write tool first" >&2; exit 1; }
{
  cat <<'EOF'
You are Claude Code acting as an independent outside voice for this repository.
Answer the user's question directly. You may inspect repository files with Read,
Grep, and Glob only. Do not use Bash. Do not edit or write files. Do not invoke
slash commands or vibestack skills.

USER QUESTION:
EOF
  cat "$USER_TEXT_FILE"
} > "$PROMPT_FILE"
```

3. Run Claude. Pass `timeout: 600000` on either Bash call below. The 540-second wrapper sits below that
10-minute gate so a stall surfaces as exit 124 with a message, never as a silent
harness kill that leaves an empty response to be read as "nothing found".

For a new session:

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
# Portable timeout: gtimeout → timeout → a polling watchdog. Stock macOS ships
# neither binary; the watchdog returns 124 on overrun, as timeout(1) does.
_CL_TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)
# A function, not an inline ${VAR:+...} prefix: zsh does not word-split that
# expansion, so "gtimeout 540" would reach execve as one argument (exit 127).
_cl() {
  if [ -n "${_CL_TO:-}" ]; then "$_CL_TO" "$@"; return; fi
  _cl_s=$1; shift
  "$@" <&0 & _cl_p=$!
  while kill -0 "$_cl_p" 2>/dev/null; do
    if [ "$_cl_s" -le 0 ]; then
      pkill -TERM -P "$_cl_p" 2>/dev/null; kill -TERM "$_cl_p" 2>/dev/null; sleep 2
      pkill -KILL -P "$_cl_p" 2>/dev/null; kill -KILL "$_cl_p" 2>/dev/null
      wait "$_cl_p" 2>/dev/null; return 124
    fi
    sleep 1; _cl_s=$((_cl_s - 1))
  done
  wait "$_cl_p"
}
_cl 540 claude -p --output-format json --disable-slash-commands --strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings '{"disableAllHooks":true}' --allowedTools Read,Grep,Glob --disallowedTools 'Bash,Edit,Write,mcp__*' < "$PROMPT_FILE" 2>"$ERR_FILE" | head -c 33554432 > "$RESP_FILE"
_CL_EXIT=${PIPESTATUS[0]:-${pipestatus[1]}}
if [ "$_CL_EXIT" = "124" ]; then
  "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log" '{"skill":"claude-consult","status":"timeout","gate":"fail","completed":false,"timeout_s":540}' >/dev/null 2>&1 || true
  echo "Claude stalled past 9 minutes. Common causes: model API stall, a long prompt, a network issue. Re-run; if it persists, split the diff or the question."
  echo "CLAUDE_RESULT: TIMEOUT"
elif [ "$_CL_EXIT" != "0" ]; then
  echo "[claude exit $_CL_EXIT] $(head -n1 "$ERR_FILE" 2>/dev/null)"
  echo "CLAUDE_RESULT: FAILED (exit $_CL_EXIT)"
else
  echo "CLAUDE_RESULT: OK"
fi
if grep -qiE "auth|login|unauthorized" "$ERR_FILE" 2>/dev/null; then
  echo "[claude auth error] $(head -n1 "$ERR_FILE")"
fi
```

For a resumed session:

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
# Portable timeout: gtimeout → timeout → a polling watchdog. Stock macOS ships
# neither binary; the watchdog returns 124 on overrun, as timeout(1) does.
_CL_TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)
# A function, not an inline ${VAR:+...} prefix: zsh does not word-split that
# expansion, so "gtimeout 540" would reach execve as one argument (exit 127).
_cl() {
  if [ -n "${_CL_TO:-}" ]; then "$_CL_TO" "$@"; return; fi
  _cl_s=$1; shift
  "$@" <&0 & _cl_p=$!
  while kill -0 "$_cl_p" 2>/dev/null; do
    if [ "$_cl_s" -le 0 ]; then
      pkill -TERM -P "$_cl_p" 2>/dev/null; kill -TERM "$_cl_p" 2>/dev/null; sleep 2
      pkill -KILL -P "$_cl_p" 2>/dev/null; kill -KILL "$_cl_p" 2>/dev/null
      wait "$_cl_p" 2>/dev/null; return 124
    fi
    sleep 1; _cl_s=$((_cl_s - 1))
  done
  wait "$_cl_p"
}
_cl 540 claude -p --resume "<session-id>" --output-format json --disable-slash-commands --strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings '{"disableAllHooks":true}' --allowedTools Read,Grep,Glob --disallowedTools 'Bash,Edit,Write,mcp__*' < "$PROMPT_FILE" 2>"$ERR_FILE" | head -c 33554432 > "$RESP_FILE"
_CL_EXIT=${PIPESTATUS[0]:-${pipestatus[1]}}
if [ "$_CL_EXIT" = "124" ]; then
  "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log" '{"skill":"claude-consult","status":"timeout","gate":"fail","completed":false,"timeout_s":540}' >/dev/null 2>&1 || true
  echo "Claude stalled past 9 minutes. Common causes: model API stall, a long prompt, a network issue. Re-run; if it persists, split the diff or the question."
  echo "CLAUDE_RESULT: TIMEOUT"
elif [ "$_CL_EXIT" != "0" ]; then
  echo "[claude exit $_CL_EXIT] $(head -n1 "$ERR_FILE" 2>/dev/null)"
  echo "CLAUDE_RESULT: FAILED (exit $_CL_EXIT)"
else
  echo "CLAUDE_RESULT: OK"
fi
if grep -qiE "auth|login|unauthorized" "$ERR_FILE" 2>/dev/null; then
  echo "[claude auth error] $(head -n1 "$ERR_FILE")"
fi
```

4. Run the parser from Shared Helpers with `CLAUDE_MODE='consult'` — unless the
   run block printed `CLAUDE_RESULT: TIMEOUT`: that run is already logged, so skip
   the parser and the log step and say Claude timed out. On
   `CLAUDE_STATUS: unavailable` or `CLAUDE_RESULT: FAILED`, say so with the reason
   instead of presenting an empty or partial answer. Otherwise present:

```
CLAUDE SAYS (consult):
============================================================
<parsed result from RESP_FILE, verbatim>
============================================================
Session saved - run /claude again to continue this conversation.
```

   Then emit ONE recommendation line:

```
Recommendation: <action> because <one-line reason that names the most actionable insight from Claude>
```

   The reason must engage with a specific point Claude made and compare it against
   an alternative (a different recommendation, the status quo, or another point).

5. Save the session id — only when step 4's parser printed `CLAUDE_STATUS: answered`.
   An errored, timed-out or unavailable run saves nothing, so the next run does
   not resume from a broken session:

```bash
RESP_FILE='<RESP_FILE>'
SESSION_ID=$(python3 - "$RESP_FILE" <<'PY'
import json, sys
try:
    obj = json.load(open(sys.argv[1]))
    print(obj.get("session_id") or "")
except Exception:
    print("")
PY
)
if [ -n "$SESSION_ID" ]; then
  mkdir -p .context
  printf "%s\n" "$SESSION_ID" > .context/claude-session-id
fi
```

6. Log the result, unless step 4 skipped it for a timeout:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log" '{"skill":"claude-consult","status":"STATUS","completed":COMPLETED,"commit":"'"$(git rev-parse --short HEAD)"'"}' >/dev/null 2>&1 || true
```

   Substitute STATUS — `answered` on `CLAUDE_STATUS: answered`, `unavailable`
   otherwise; COMPLETED — `true` when answered, `false` when unavailable.

7. Cleanup:

```bash
PROMPT_FILE='<PROMPT_FILE>'
RESP_FILE='<RESP_FILE>'
ERR_FILE='<ERR_FILE>'
USER_TEXT_FILE='<USER_TEXT_FILE>'
rm -f "$PROMPT_FILE" "$RESP_FILE" "$ERR_FILE" "$USER_TEXT_FILE"
```

---

## Error Handling

- **Binary not found:** Stop with install instructions.
- **Auth error in stderr from the actual run:** Surface the line and ask the user to re-authenticate. Never gate on credentials up front (Step 0).
- **Timeout (exit 124):** The run block logs it and prints the stall message; report the run as unavailable.
- **Parse failure, error result, empty or truncated response:** The parser prints `CLAUDE_STATUS: unavailable (<reason>)`. Show stderr from `$ERR_FILE` and report the run as unavailable — never as a review that found nothing.
- **Resume failure:** Only when the error names an invalid, expired or missing session id, delete `.context/claude-session-id` and retry with a fresh session. On any other error, report it and keep `.context/claude-session-id`.

---

## Important Rules

- Nested Claude is read-only in consult mode and tool-less in review/challenge.
- Always include `--disable-slash-commands` and the hermetic flags from Safety Boundary.
- Never pass nested Claude `Bash`, `Edit`, or `Write`.
- Never interpolate user text into a shell command.
- Present Claude's response faithfully, then add any host-agent synthesis after it.
