#!/usr/bin/env bash
# Tests for bin/vibe-skill-usage: counts typed and model-invoked skills from
# Claude transcripts (including nested subagent transcripts) and the analytics
# file, honours the --days window, tolerates malformed lines, and never prints
# message text.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/vibe-skill-usage"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

H="$TMP/home"
P="$H/.claude/projects/p1"
mkdir -p "$P/s1/subagents" "$H/.vibestack/analytics"
python3 -I - "$P" "$H/.vibestack/analytics/skill-usage.jsonl" <<'PY'
import json, sys, datetime
p, analytics = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
ts = lambda days: (now - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def use(name, days):
    return {"type": "assistant", "timestamp": ts(days),
            "message": {"content": [{"type": "tool_use", "name": "Skill", "input": {"skill": name}}]}}
top = [
    {"type": "user", "timestamp": ts(1),
     "message": {"content": "<command-name>/ship</command-name>\n<command-args>SECRET-MARKER-7b2</command-args>"}},
    use("ship", 1),
    use("retro", 400),
    {"type": "assistant", "message": {"content": "no timestamp, plain text"}},
]
with open(p + "/s1.jsonl", "w") as f:
    for e in top:
        f.write(json.dumps(e) + "\n")
    f.write("{this is not json\n")
with open(p + "/s1/subagents/agent-x.jsonl", "w") as f:
    f.write(json.dumps(use("codex", 2)) + "\n")
with open(analytics, "w") as f:
    f.write(json.dumps({"ts": ts(1), "skill": "ship", "slug": "x"}) + "\n")
PY

run() { HOME="$H" VIBESTACK_HOME="$H/.vibestack" "$BIN" "$@" 2>&1; }

[ -x "$BIN" ] && ok "vibe-skill-usage is executable" || no "vibe-skill-usage missing or not executable"

out=$(run --days 30); rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || no "exit $rc: $out"
row() { grep -E "^$1[[:space:]]" <<<"$out"; }
r=$(row ship)
[ "$(awk '{print $2, $3}' <<<"$r")" = "1 1" ] && ok "ship typed=1 model=1" || no "ship row: '$r'"
r=$(row codex)
[ "$(awk '{print $3, $4}' <<<"$r")" = "1 1" ] && ok "codex model=1 nested=1" || no "codex row: '$r'"
[ -z "$(row retro)" ] && ok "retro outside the 30-day window" || no "retro counted at --days 30"
grep -q 'TRANSCRIPTS: 2 read, 1 unreadable' <<<"$out" && ok "1 unreadable line counted" || no "transcript footer: $out"
grep -q 'ANALYTICS: 1 rows' <<<"$out" && ok "analytics rows reported" || no "analytics footer: $out"
grep -q 'RUNTIMES: claude measured; cursor, kiro, codex unmeasured' <<<"$out" \
  && ok "unmeasured runtimes named" || no "runtimes footer: $out"
grep -q 'SECRET-MARKER-7b2' <<<"$out" && no "message text leaked" || ok "message text never printed"
grep -q "$H" <<<"$out" && no "transcript path leaked" || ok "no paths printed"

out=$(run --days 3650)
[ -n "$(row retro)" ] && ok "retro present at --days 3650" || no "retro missing at --days 3650: $out"

out=$(run --days 30 --json)
if python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); assert isinstance(d, dict)' <<<"$out" 2>/dev/null; then
  ok "--json parses"
else
  no "--json does not parse: $out"
fi
grep -q 'SECRET-MARKER-7b2' <<<"$out" && no "message text leaked in --json" || ok "--json has no message text"

mkdir -p "$TMP/empty"
out=$(HOME="$TMP/empty" VIBESTACK_HOME="$TMP/empty/.vibestack" "$BIN" --claude-dir "$TMP/empty/.claude" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'TRANSCRIPTS: 0 read' <<<"$out" && ok "empty claude-dir: 0 read, exit 0" \
  || no "empty claude-dir (rc=$rc): $out"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
