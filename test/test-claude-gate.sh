#!/usr/bin/env bash
# test-claude-gate.sh — /claude grades every nested run fail-closed.
#
# A nested `claude --print` run can error, time out, or answer with prose that
# tags nothing, and each of those used to read as a review that found nothing.
# The parser in skills/claude/SKILL.md turns them into `unavailable` (exit 1) or
# `GATE: UNVERIFIED` (exit 4); only a [P2]/[P3]-only or NO_FINDINGS answer passes.
#
# The parser is extracted from the rendered skill and run against fixtures, so
# this fails when the skill text regresses, not only when a copy of it does.
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
awk '/python3 - "\$RESP_FILE" .*<<.VIBE_CLAUDE_PARSE_PY.$/{on=1; next} /^VIBE_CLAUDE_PARSE_PY$/{on=0} on' "$SKILL" > "$PARSER"
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
success() { python3 -c 'import json,sys; print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":sys.argv[1],"session_id":"s1","usage":{"input_tokens":1,"output_tokens":2}}))' "$1"; }

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

echo "parser: consult"
expect "consult answer -> answered, exit 0" consult 0 "CLAUDE_STATUS: answered" \
  "$(success 'The retry loop backs off exponentially.')"
expect "consult prints the session id" consult 0 "SESSION_ID:s1" \
  "$(success 'An answer.')"

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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
