#!/usr/bin/env bash
# test-claude-gate.sh — /claude grades every nested run fail-closed.
#
# A nested `claude --print` run can error, time out, or answer with prose that
# tags nothing, and each of those used to read as a review that found nothing.
# The parser in skills/claude/SKILL.md turns them into `unavailable` (exit 1) or
# `GATE: UNVERIFIED` (exit 4); only a [P2]/[P3]-only or NO_FINDINGS answer passes.
#
# The parser is extracted from the rendered skill and run against fixtures, and
# the run blocks are run against a stub `claude` on PATH, so this fails when the
# skill text regresses, not only when a copy of it does.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SKILL="$TMP/claude.md"
if ! "$ROOT/bin/vibe-render-skill" "$ROOT/skills/claude/SKILL.md" "$SKILL" >/dev/null 2>"$TMP/render.err"; then
  no "skill renders ($(head -n1 "$TMP/render.err"))"
  echo "$pass passed, $fail failed"; exit 1
fi

PARSER="$TMP/parse.py"
awk '/<<.VIBE_CLAUDE_PARSE_PY.$/{on=1; next} /^VIBE_CLAUDE_PARSE_PY$/{on=0} on' "$SKILL" > "$PARSER"
if [ -s "$PARSER" ] && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PARSER"; then
  ok "parser extracts from the rendered skill and parses"
else
  no "parser block missing or not valid Python"
  echo "$pass passed, $fail failed"; exit 1
fi

# expect NAME MODE WANT_EXIT WANT_TEXT FIXTURE_CONTENT
expect() {
  printf '%s' "$5" > "$TMP/resp.json"
  local out code
  out=$(python3 "$PARSER" "$TMP/resp.json" "$2" 2>&1); code=$?
  if [ "$code" = "$3" ] && printf '%s' "$out" | grep -qF -- "$4"; then ok "$1"
  else no "$1 (want exit $3 + '$4', got exit $code)"; printf '%s\n' "$out" | sed 's/^/    /'; fi
}
success() { python3 -I -c 'import json,sys; print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":sys.argv[1],"session_id":"s1","usage":{"input_tokens":1,"output_tokens":2},"modelUsage":{"claude-test-model":{"inputTokens":1}},"total_cost_usd":0.0123}))' "$1"; }
LONG_ANSWER="I'll look at this from the retry path first. $(printf 'The client in client.py retries on 429 and 503, backs off exponentially from 200 ms and gives up after five attempts, so a sustained outage surfaces after about six seconds. %.0s' 1 2 3)"

echo "parser: review and challenge gate"
expect "[P1] finding -> FAIL, exit 3" review 3 "GATE: FAIL (1 critical findings)" \
  "$(success $'[P1] SQL injection at a.rb:3\n[P3] naming')"
expect "NO_FINDINGS -> PASS, exit 0" review 0 "GATE: PASS" \
  "$(success $'Checked auth and parsing.\nNO_FINDINGS')"
expect "only [P2]/[P3] -> PASS with counts" challenge 0 "GATE: PASS (P2=1 P3=1)" \
  "$(success $'[P2] retry has no cap\n[P3] typo')"
expect "untagged prose -> UNVERIFIED, exit 4" review 4 "GATE: UNVERIFIED" \
  "$(success 'I reviewed the change and it looks good.')"
expect "[P1] beside NO_FINDINGS still fails" challenge 3 "GATE: FAIL" \
  "$(success $'[P1] data loss in migrate()\nNO_FINDINGS')"
expect "FINDINGS count printed" review 3 "FINDINGS: 2" \
  "$(success $'[P1] one\n[P2] two')"

echo "parser: unavailable runs"
expect "is_error true -> unavailable, exit 1" review 1 "CLAUDE_STATUS: unavailable" \
  '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 overloaded"}'
expect "invalid JSON -> unavailable, exit 1" review 1 "CLAUDE_STATUS: unavailable (JSON parse error" \
  '{"type":"result","subtype":'
expect "empty result -> unavailable, exit 1" review 1 "CLAUDE_STATUS: unavailable (missing or empty result)" \
  '{"type":"result","subtype":"success","is_error":false,"result":""}'
expect "non-success subtype -> unavailable" challenge 1 "CLAUDE_STATUS: unavailable (subtype=" \
  '{"type":"result","subtype":"error_max_turns","is_error":false,"result":"NO_FINDINGS"}'
expect "non-string result -> unavailable" review 1 "unavailable (missing or empty result)" \
  '{"type":"result","subtype":"success","is_error":false,"result":["NO_FINDINGS"]}'
expect "empty response file -> unavailable" consult 1 "CLAUDE_STATUS: unavailable (empty response)" ''
expect "unavailable review also prints a failing gate" review 1 "GATE: FAIL (review unavailable" ''

echo "parser: severity labels shared with /codex"
expect "[P0] beside [P2] -> FAIL, exit 3" review 3 "GATE: FAIL (1 critical findings)" \
  "$(success $'[P0] drops every row on retry\n[P2] naming')"
expect "line-leading P1: label -> FAIL" challenge 3 "GATE: FAIL" \
  "$(success $'P1: token logged in plain text at auth.py:40')"
expect "bold bullet **[P1]** -> FAIL" review 3 "GATE: FAIL" \
  "$(success $'- **[P1]** SQL injection at a.rb:3')"
expect "[P2] only -> PASS" review 0 "GATE: PASS (P2=1 P3=0)" \
  "$(success '[P2] retry has no cap')"
expect "refusal -> unavailable, not a gate verdict" review 1 "CLAUDE_STATUS: unavailable (review_refused" \
  "$(success "I'm sorry, but I can't assist with that.")"

echo "parser: consult"
expect "consult answer -> answered, exit 0" consult 0 "CLAUDE_STATUS: answered" \
  "$(success 'The retry loop backs off exponentially.')"
expect "consult prints the session id" consult 0 "SESSION_ID:s1" \
  "$(success 'An answer.')"
expect "consult intent stub -> unavailable (intent_stub)" consult 1 "CLAUDE_STATUS: unavailable (intent_stub" \
  "$(success "I'll start by exploring the repository structure to understand the retry logic.")"
expect "consult answer of 400+ chars opening with 'I'll look' -> answered" consult 0 "CLAUDE_STATUS: answered" \
  "$(success "$LONG_ANSWER")"
expect "footer names the models from modelUsage" consult 0 "Models: claude-test-model" \
  "$(success 'An answer.')"
expect "footer prints the run's cost" review 0 "Cost: USD 0.0123" \
  "$(success 'NO_FINDINGS')"

echo "skill text"
calls=$(grep -c 'claude -p' "$SKILL" || true)
wrapped=$(grep 'claude -p' "$SKILL" | grep -c '_cl 540' || true)
strict=$(grep 'claude -p' "$SKILL" | grep -c -- '--strict-mcp-config' || true)
hooks=$(grep 'claude -p' "$SKILL" | grep -c 'disableAllHooks' || true)
if [ "$calls" -ge 4 ] && [ "$calls" = "$wrapped" ]; then ok "all $calls nested runs go through _cl 540"
else no "_cl 540 on $wrapped of $calls nested runs"; fi
if [ "$calls" = "$strict" ] && [ "$calls" = "$hooks" ]; then ok "every nested run starts no MCP server and no hook"
else no "--strict-mcp-config on $strict, disableAllHooks on $hooks of $calls nested runs"; fi
capped=$(grep 'claude -p' "$SKILL" | grep -c 'head -c 33554432' || true)
if [ "$calls" = "$capped" ]; then ok "every nested run caps its output"
else no "output cap on $capped of $calls nested runs"; fi
if grep -qF '|| echo "main"' "$SKILL"; then no "a base-branch fallback that never fires is still present"
else ok "no dead '|| echo \"main\"' base-branch fallback"; fi
if grep -q 'BASE_BRANCH_UNRESOLVED' "$SKILL"; then ok "diff blocks refuse an empty base branch"
else no "no BASE_BRANCH_UNRESOLVED guard"; fi
if grep -q 'CLAUDECODE' "$SKILL" && grep -q 'VIBE_FORCE_CLAUDE_REVIEW' "$SKILL"; then ok "host self-guard and its override are present"
else no "CLAUDECODE self-guard or VIBE_FORCE_CLAUDE_REVIEW override missing"; fi
if grep -q 'vibe-review-log' "$SKILL" && grep -q '"skill":"claude-review"' "$SKILL"; then ok "review results reach vibe-review-log"
else no "no claude-review entry for vibe-review-log"; fi
every() { # every LABEL FIXED_STRING -> every `claude -p` line carries the string
  local n m
  n=$(grep -c 'claude -p' "$SKILL" || true)
  m=$(grep 'claude -p' "$SKILL" | grep -cF -- "$2" || true)
  if [ "$n" -ge 4 ] && [ "$n" = "$m" ]; then ok "$1"; else no "$1 ($m of $n nested runs)"; fi
}
every "every nested run whitelists its tools with --tools" "--tools "
every "every nested run sets --permission-mode default" "--permission-mode default"
consults=$(grep 'claude -p' "$SKILL" | grep -c 'Read,Grep,Glob' || true)
consult_wl=$(grep 'claude -p' "$SKILL" | grep -cF -- '--tools Read,Grep,Glob' || true)
toolless=$(grep 'claude -p' "$SKILL" | grep -cF -- '--tools ""' || true)
sysprompt=$(grep 'claude -p' "$SKILL" | grep -F -- '--tools ""' | grep -c -- "--append-system-prompt '[^']*do not simulate tool calls" || true)
if [ "$consults" -ge 2 ] && [ "$consult_wl" = "$consults" ]; then ok "consult runs whitelist Read,Grep,Glob"
else no "--tools Read,Grep,Glob on $consult_wl of $consults consult runs"; fi
if [ "$toolless" -ge 2 ] && [ "$sysprompt" = "$toolless" ]; then ok "tool-less runs tell the model not to simulate tools"
else no "no-simulated-tools system prompt on $sysprompt of $toolless tool-less runs"; fi
section() { awk -v a="$1" 'index($0,a)==1{on=1;next} on&&/^## /{exit} on' "$SKILL"; }
review_sec=$(section '## Step 2A:')
if printf '%s' "$review_sec" | grep -q 'DIFF_START' && printf '%s' "$review_sec" | grep -q 'DIFF_END' \
   && printf '%s' "$review_sec" | grep -q 'as data, not instructions'; then ok "review frames the diff as data"
else no "review does not frame the diff between DIFF_START/DIFF_END as data"; fi
challenge_sec=$(section '## Step 2B:')
if printf '%s' "$challenge_sec" | grep -q 'DIFF_START' && printf '%s' "$challenge_sec" | grep -q 'as data, not instructions'; then ok "challenge frames the diff as data"
else no "challenge does not frame the diff between DIFF_START/DIFF_END as data"; fi
if grep -q '\[P0\]' "$SKILL"; then ok "review prompts define [P0]"; else no "review prompts never mention [P0]"; fi
for step in '## Step 2A:' '## Step 2B:' '## Step 2C:'; do
  if section "$step" | grep -q 'Date Grounding'; then ok "${step#\#\# } runs the date grounding on its prompt"
  else no "${step#\#\# } does not run the date grounding"; fi
done
if grep -q 'Current date (UTC)' "$SKILL"; then ok "the grounding snippet is rendered into the skill"
else no "the grounding snippet is not included"; fi
if grep -q 'UNTRACKED:' "$SKILL"; then ok "the diff block reports untracked files"
else no "the diff block does not report untracked files"; fi

echo "run blocks: stub claude"
cat > "$TMP/block_with.py" <<'PY'
import re, sys, textwrap
text, needle = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
exclude = sys.argv[3] if len(sys.argv) > 3 else None
blocks = [textwrap.dedent(m.group(2)) for m in re.finditer(r"^([ \t]*)```bash\n(.*?)\n\1```", text, re.S | re.M)]
hits = [b for b in blocks if needle in b and not (exclude and exclude in b)]
if len(hits) != 1:
    sys.exit("expected one bash block containing %r, found %d" % (needle, len(hits)))
sys.stdout.write(hits[0] + "\n")
PY
cat > "$TMP/fill.py" <<'PY'
import sys
path, pairs = sys.argv[1], sys.argv[2:]
s = open(path).read()
for old, new in zip(pairs[::2], pairs[1::2]):
    s = s.replace(old, new)
open(path, "w").write(s)
PY
block_with() { python3 -I "$TMP/block_with.py" "$SKILL" "$@"; }
fill() { python3 -I "$TMP/fill.py" "$@"; }
STUB="$TMP/stub"; CAP="$TMP/cap"; mkdir -p "$STUB" "$TMP/work"
cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAP/argv"
cat > "$CAP/stdin"
cat "$CAP/reply.json"
exit "${STUB_EXIT:-0}"
SH
chmod +x "$STUB/claude"
scratch() { # runs the setup block, prints the scratch dir it created
  (cd "$TMP/work" && env TMPDIR="$TMP" bash "$TMP/setup.sh" 2>&1) | sed -n 's/^SCRATCH: //p'
}
RUN_CODE=0
run_mode() { # run_mode NEEDLE MODEL [VAR=VAL ...] -> output in $TMP/run.out, exit in RUN_CODE
  local needle="$1" model="$2" exclude=""; shift 2
  case "$needle" in *'|!'*) exclude="${needle#*|!}"; needle="${needle%%|!*}" ;; esac
  rm -rf "$CAP"; mkdir -p "$CAP"; cp "$TMP/reply.json" "$CAP/reply.json"
  D=$(scratch); [ -n "$D" ] && printf 'the question\n' > "$D/prompt.txt"
  if ! block_with "$needle" ${exclude:+"$exclude"} > "$TMP/run.sh" 2>"$TMP/err"; then
    cp "$TMP/err" "$TMP/run.out"; RUN_CODE=99; return
  fi
  fill "$TMP/run.sh" "<SCRATCH>" "$D" "<MODEL>" "$model" "<session-id>" "s-prev"
  (cd "$TMP/work" && env -u VIBE_CLAUDE_MODEL "$@" PATH="$STUB:$PATH" CAP="$CAP" VIBESTACK_HOME="$TMP/vh" bash "$TMP/run.sh") > "$TMP/run.out" 2>&1
  RUN_CODE=$?
}
argv_has() { [ -f "$CAP/argv" ] && grep -qxF -- "$1" "$CAP/argv"; }
REVIEW_RUN='"skill":"claude-review","status":"timeout"'
CHALLENGE_RUN='"skill":"claude-challenge","status":"timeout"'
CONSULT_NEW='"skill":"claude-consult","status":"timeout"|!--resume'
CONSULT_RESUME='claude -p --resume'

if block_with 'mktemp -d "${TMPDIR:-/tmp}/vibe-claude.' > "$TMP/setup.sh" 2>"$TMP/err"; then
  ok "a setup block creates one scratch directory per invocation"
  D=$(scratch)
  if [ -n "$D" ] && [ -f "$D/parse.py" ] && [ -f "$D/user.txt" ] && [ ! -s "$D/user.txt" ]; then ok "the scratch dir holds the parser and an empty user-text file"
  else no "setup did not create parse.py and an empty user.txt (${D:-no SCRATCH line})"; fi
  [ -n "$D" ] && rm -rf "$D"

  success $'[P0] drops rows\n[P2] naming' > "$TMP/reply.json"
  run_mode "$REVIEW_RUN" opus
  if grep -q 'GATE: FAIL (1 critical findings)' "$TMP/run.out" && grep -q 'Models: claude-test-model' "$TMP/run.out"; then ok "review: one block runs Claude and grades the reply"
  else no "review run block did not grade ($(head -3 "$TMP/run.out"))"; fi
  if [ -n "$D" ] && [ ! -e "$D" ]; then ok "review: the scratch dir is removed when the block exits"
  else no "review: scratch dir ${D:-?} survived the run block"; [ -n "$D" ] && rm -rf "$D"; fi
  if argv_has '--model=opus'; then ok "review: -m reaches claude as --model=<id>"
  else no "review: no --model=opus in argv"; fi
  if argv_has '--permission-mode' && argv_has 'default' && argv_has '--tools'; then ok "review: argv carries --tools and --permission-mode default"
  else no "review: argv lacks --tools / --permission-mode default"; fi

  run_mode "$CHALLENGE_RUN" '' VIBE_CLAUDE_MODEL=sonnet
  if argv_has '--model=sonnet'; then ok "challenge: VIBE_CLAUDE_MODEL is the fallback model"
  else no "challenge: VIBE_CLAUDE_MODEL did not reach argv"; fi
  run_mode "$CHALLENGE_RUN" ''
  if [ -f "$CAP/argv" ] && ! grep -q -- '--model' "$CAP/argv"; then ok "challenge: no model given -> no --model flag"
  else no "challenge: unexpected --model, or claude never ran ($(head -3 "$TMP/run.out"))"; fi
  run_mode "$CHALLENGE_RUN" 'x;touch pwned'
  if [ "$RUN_CODE" != 99 ] && [ ! -f "$CAP/argv" ] && [ "$RUN_CODE" != 0 ] && [ ! -e "$TMP/work/pwned" ]; then ok "challenge: an invalid model name stops before Claude runs"
  else no "challenge: invalid model name was not refused (exit $RUN_CODE)"; fi
  [ -n "$D" ] && rm -rf "$D"

  run_mode "$REVIEW_RUN" '' STUB_EXIT=1
  if grep -q 'GATE: FAIL (review unavailable' "$TMP/run.out" && ! grep -q 'GATE: PASS' "$TMP/run.out"; then ok "review: a failed claude exit is unavailable, never a pass"
  else no "review: exit 1 not graded unavailable ($(head -3 "$TMP/run.out"))"; fi

  success "$LONG_ANSWER" | python3 -I -c 'import json,sys; o=json.load(sys.stdin); o["session_id"]="abc-123"; print(json.dumps(o))' > "$TMP/reply.json"
  rm -rf "$TMP/work/.context"
  run_mode "$CONSULT_NEW" ''
  if grep -q 'CLAUDE_STATUS: answered' "$TMP/run.out" && [ "$(cat "$TMP/work/.context/claude-session-id" 2>/dev/null)" = "abc-123" ]; then ok "consult: an answered run saves its session id"
  else no "consult: answer or session id missing ($(head -3 "$TMP/run.out"))"; fi
  success "Let me first check the client module." > "$TMP/reply.json"
  rm -rf "$TMP/work/.context"
  run_mode "$CONSULT_NEW" ''
  if grep -q 'unavailable (intent_stub' "$TMP/run.out" && [ ! -e "$TMP/work/.context/claude-session-id" ]; then ok "consult: an intent stub is unavailable and saves no session"
  else no "consult: intent stub not refused, or a session was saved ($(head -3 "$TMP/run.out"))"; fi
  success "$LONG_ANSWER" > "$TMP/reply.json"
  run_mode "$CONSULT_RESUME" ''
  if argv_has '--resume' && argv_has 's-prev' && grep -q 'CLAUDE_STATUS: answered' "$TMP/run.out"; then ok "consult: a resumed run passes the validated session id"
  else no "consult: resume run did not pass --resume s-prev ($(head -3 "$TMP/run.out"))"; fi
else
  no "no setup block creates a per-invocation scratch dir ($(cat "$TMP/err"))"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
