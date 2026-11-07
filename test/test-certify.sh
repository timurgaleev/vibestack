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

# Copilot's project scope is .github/skills; certify must look there, not in
# a .copilot/ tree that install never writes.
out=$(env -u COPILOT_HOME bash "$ROOT/bin/vibe-certify" copilot 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q "copilot: PASS" <<<"$out" && ok "copilot target certifies clean" || no "copilot certify rc=$rc: $(tail -3 <<<"$out")"

# Unknown target: install rejects it → certify must report FAIL, not pass silently.
out=$(bash "$ROOT/bin/vibe-certify" no-such-target 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q "no-such-target: FAIL" <<<"$out" && ok "unknown target fails closed" || no "unknown target rc=$rc"

# Typed-only skills: `disable-model-invocation: true` must survive rendering, and
# a skill another workflow hands off to through the Skill tool must never carry
# it, or that hand-off silently stops working.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fm() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$1"; }
bash "$ROOT/bin/vibe-render-skill" "$ROOT/skills/land-and-deploy/SKILL.md" "$TMP/land.md" >/dev/null 2>&1
fm "$TMP/land.md" | grep -qx 'disable-model-invocation: true' \
  && ok "land-and-deploy renders as typed-only" || no "land-and-deploy is model-invocable after rendering"
fm "$ROOT/skills/land-and-deploy/SKILL.md" | grep -q '^triggers:' \
  && no "land-and-deploy still declares auto-invoke triggers" || ok "land-and-deploy declares no auto-invoke triggers"
marked=""
for f in "$ROOT"/skills/*/SKILL.md; do
  fm "$f" | grep -qx 'disable-model-invocation: true' && marked="$marked $(basename "$(dirname "$f")")"
done
bad=""
for s in $marked; do
  case "$s" in land-and-deploy) ;; *) bad="$bad $s(not allowed)" ;; esac
  for caller in autoplan ship; do
    grep -qE "/$s([^[:alnum:]_-]|\$)" "$ROOT/skills/$caller/SKILL.md" && bad="$bad $s(named by $caller)"
  done
done
[ -z "$bad" ] && ok "no skill reachable from /autoplan or /ship is typed-only" || no "typed-only skill reachable:$bad"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
