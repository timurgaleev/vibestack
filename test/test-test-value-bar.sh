#!/usr/bin/env bash
# test-test-value-bar.sh — the test value bar reaches every skill that writes,
# proposes or reviews tests, and the copies cannot drift apart.
#
# lib/snippets/test-value-bar.md is included by /ship, /plan-eng-review, /qa and
# /qa-only. review/specialists/testing.md is installed as a symlink, not
# rendered, so it carries the four questions inline; this suite holds the two
# copies to the same wording.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNIPPET="$ROOT/lib/snippets/test-value-bar.md"
SPECIALIST="$ROOT/skills/review/specialists/testing.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -Fq -- "$1" "$2"; }

[ -f "$SNIPPET" ] || { echo "missing $SNIPPET" >&2; exit 1; }

echo "snippet"
QUESTIONS="$TMP/questions.txt"
grep -E '^[1-4]\. ' "$SNIPPET" > "$QUESTIONS"
[ "$(wc -l < "$QUESTIONS" | tr -d ' ')" = 4 ] \
  && ok "snippet lists four value questions" || no "snippet does not list exactly four questions"
has 'Value: protects=' "$SNIPPET" && ok "snippet defines the value card" || no "value card missing"
has 'never counts as covering a path' "$SNIPPET" \
  && ok "weak tests never count as coverage" || no "weak-test coverage rule missing"
has 'must fail, on its own assertion, against the code before the repair' "$SNIPPET" \
  && ok "regression proof requires red before the fix" || no "red-before-fix rule missing"
has 'pass at the base commit as a control' "$SNIPPET" \
  && ok "regression proof uses base as the control" || no "base control missing"
if grep -Eq '^\{\{include ' "$SNIPPET"; then
  no "snippet contains a nested include"
else
  ok "snippet has no nested include"
fi

echo "rendered skills"
for skill in ship plan-eng-review qa qa-only; do
  src="$ROOT/skills/$skill/SKILL.md"
  out="$TMP/$skill.md"
  if ! "$ROOT/bin/vibe-render-skill" "$src" "$out" >/dev/null 2>&1; then
    no "$skill: render failed"; continue
  fi
  has '**Test value bar.**' "$out" \
    && ok "$skill: value bar expands" || no "$skill: value bar not included"
  if has '{{include lib/snippets/test-value-bar.md}}' "$out"; then
    no "$skill: include directive left unexpanded"
  fi
done

PLAN="$TMP/plan-eng-review.md"
if [ -s "$PLAN" ]; then
  has '## Tests to Retire' "$PLAN" \
    && ok "plan-eng-review: test plan has Tests to Retire" || no "plan-eng-review: Tests to Retire missing"
  if has 'too many tests than too few' "$PLAN" || has '100% coverage is the goal' "$PLAN"; then
    no "plan-eng-review: still asks for test volume over value"
  else
    ok "plan-eng-review: no test-volume preference"
  fi
  has '[★   WEAK]' "$PLAN" \
    && ok "plan-eng-review: diagram marks weak-only paths as gaps" || no "plan-eng-review: weak marker missing"
  has 'Value: protects={...}; fails_when={...}' "$PLAN" \
    && ok "plan-eng-review: test plan template carries the value card" || no "plan-eng-review: value card missing from the test plan template"
  has 'require the regression proof from the value bar' "$PLAN" \
    && ok "plan-eng-review: regressions require the proof" || no "plan-eng-review: regression proof requirement missing"
fi

QA="$TMP/qa.md"
if [ -s "$QA" ]; then
  if has 'Mock all external dependencies' "$QA"; then
    no "qa: still mocks every dependency"
  else
    ok "qa: no blanket mocking"
  fi
  has 'prove it is red without the fix' "$QA" \
    && ok "qa: regression test is run without the fix" || no "qa: red proof step missing"
  has '// Value: protects={...}' "$QA" \
    && ok "qa: attribution comment carries the value card" || no "qa: value card missing from the attribution comment"
  has 'only add the failing case for the bug being fixed' "$QA" \
    && ok "qa: existing test files only gain the failing case" || no "qa: rule on editing existing test files missing"
fi

QAO="$TMP/qa-only.md"
if [ -s "$QAO" ]; then
  has 'why_new=unchecked' "$QAO" \
    && ok "qa-only: unanswerable card fields are marked unchecked" || no "qa-only: why_new=unchecked rule missing"
fi

echo "review testing specialist"
while IFS= read -r q; do
  text="${q#[1-4]. }"
  has "$text" "$SPECIALIST" || { no "specialist drifted from snippet question: ${text:0:60}"; continue; }
  ok "specialist carries: ${text:0:50}"
done < "$QUESTIONS"
for needle in 'Assertion-free tests' 'Self-comparisons' 'Regression test without red proof' \
              'a low-value test never' 'Retention bar'; do
  has "$needle" "$SPECIALIST" && ok "specialist: $needle" || no "specialist missing: $needle"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
