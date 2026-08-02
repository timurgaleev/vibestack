#!/usr/bin/env bash
# Smoke test for bin/vibe-certify: the claude target must certify cleanly, and
# a sabotaged fixture must fail. Uses the claude target only to keep it fast.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

out=$(bash "$ROOT/bin/vibe-certify" claude 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q "claude: PASS" <<<"$out" && ok "claude target certifies clean" || no "claude certify rc=$rc: $(tail -1 <<<"$out")"

# Unknown target: install rejects it → certify must report FAIL, not pass silently.
out=$(bash "$ROOT/bin/vibe-certify" no-such-target 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q "no-such-target: FAIL" <<<"$out" && ok "unknown target fails closed" || no "unknown target rc=$rc"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
