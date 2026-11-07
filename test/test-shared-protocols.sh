#!/usr/bin/env bash
# test-shared-protocols.sh — the claim, completeness, question and memory rules
# in the shared preamble snippets reach the skills that include them, and the
# three snippets stay inside their byte budget.
#
# working-protocols.md renders into ~50 skills and decision-brief.md into ~48,
# so every byte added here is paid fifty times over. The cap below is the
# budget; raise it only by trimming elsewhere in the same change.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WP="$ROOT/lib/snippets/working-protocols.md"
DB="$ROOT/lib/snippets/decision-brief.md"
BP="$ROOT/lib/snippets/brain-preflight.md"
BUDGET=13450
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -Fq -- "$1" "$2"; }
check() { if has "$2" "$3"; then ok "$1"; else no "$1"; fi; }

for f in "$WP" "$DB" "$BP"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

echo "claims need evidence"
check "section is titled for every claim" '### Claims need evidence' "$WP"
if has 'Claimed limitations need evidence' "$WP"; then
  no "old limitations-only title still present"
else
  ok "old limitations-only title removed"
fi
check "DONE requires evidence for the final consumed inputs" 'final consumed inputs' "$WP"
check "DONE names reused results" 'any reused result. Anything not' "$WP"
check "unverified work is DONE_WITH_CONCERNS, not DONE" 'not independently verified makes it' "$WP"
check "execution cites command and revision" 'command plus the revision' "$WP"
check "silenced stderr is not evidence" 'stderr was silenced' "$WP"
check "mock evidence is not live evidence" 'mock or fixture' "$WP"
check "done-but-unverified is not done" '"done, unverified" is not done' "$WP"
check "a checked null result counts" 'A checked null result is a result' "$WP"
check "agreeing agents are one datum" 'one datum' "$WP"
for claim in 'tests pass' 'build works' 'bug fixed' 'delegated work done' 'requirements met'; do
  if grep -Eq "^\| ${claim} \|" "$WP"; then
    ok "claim table row: $claim"
  else
    no "claim table row missing: $claim"
  fi
done

echo "completeness is coverage"
check "completeness is coverage of the stated requirement" 'complete coverage of the stated requirement' "$WP"
check "no code beyond the requirement" 'no code beyond it' "$WP"
check "smaller diff wins at equal coverage" 'prefer the smaller diff' "$WP"
check "adjacent issues are reported, not fixed" 'reported, not fixed' "$WP"
if has 'boil the ocean' "$WP"; then
  no "maximalist completeness heading still present"
else
  ok "maximalist completeness heading removed"
fi

echo "observable questions"
check "self-check runs a free read-only probe instead of asking" 'run it and report the result instead of asking' "$DB"
check "only preference and state-changing or paid checks reach the user" 'state-changing or paid' "$DB"
check "a one-way or destructive step is always asked" 'paid checks, and any one-way or' "$DB"
check "a failed or inconclusive check is asked" 'check fails or settles nothing' "$DB"
check "a fact only the user knows is asked" 'only the user knows the answer' "$DB"

echo "brain preflight"
check "product and persona answers are confirmed in-session" 'confirmed in this session' "$BP"

echo "budget"
total=$(cat "$WP" "$DB" "$BP" | wc -c | tr -d ' ')
if [ "$total" -le "$BUDGET" ]; then
  ok "three snippets total $total B (cap $BUDGET B)"
else
  no "three snippets total $total B, over the $BUDGET B cap"
fi

echo "rendered"
out="$TMP/plan-ceo-review.md"
if "$ROOT/bin/vibe-render-skill" "$ROOT/skills/plan-ceo-review/SKILL.md" "$out" >/dev/null 2>&1; then
  check "plan-ceo-review: claim rules expand" '### Claims need evidence' "$out"
  check "plan-ceo-review: question rule expands" 'state-changing or paid' "$out"
  check "plan-ceo-review: preflight rule expands" 'confirmed in this session' "$out"
else
  no "plan-ceo-review: render failed"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
