#!/usr/bin/env bash
# test-qa-rubric.sh — /qa and /qa-only score, count and choose a surface the
# same way.
#
#   - lib/snippets/qa-health-rubric.md renders byte-identical into both skills:
#     the accessibility checks, severity definitions, a final score divided by
#     the weights actually scored (never a plain Σ that hands an unrun category
#     its weight), the counting rules and the same-coverage guard on deltas.
#   - /qa runs the accessibility checks and its quick mode leaves Accessibility
#     unscored; Phase 9 and regression deltas honour the same-coverage guard.
#   - A diff with no identifiable page selects a functional surface (qa-scope,
#     qa-functional) instead of a homepage smoke test; rule 12 binds only a
#     selected browser surface; /qa-only may read source to map a functional
#     contract; the functional report template has outcomes and no score.
#   - /qa takes test detection and base-branch detection from the shared
#     snippets, so they render line for line.
#
# Usage: test-qa-rubric.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUBRIC="$ROOT/lib/snippets/qa-health-rubric.md"
SCOPE="$ROOT/lib/snippets/qa-scope.md"
FUNC="$ROOT/lib/snippets/qa-functional.md"
TEMPLATE="$ROOT/skills/qa/templates/functional-report-template.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
hasF() { grep -Fq -- "$1" "$2" 2>/dev/null; }
hasE() { grep -Eq -- "$1" "$2" 2>/dev/null; }
checkF() { if hasF "$2" "$3"; then ok "$1"; else no "$1"; fi; }
checkE() { if hasE "$2" "$3"; then ok "$1"; else no "$1"; fi; }
refuteF() { if hasF "$2" "$3"; then no "$1: $(grep -F -- "$2" "$3" | head -1 | cut -c1-90)"; else ok "$1"; fi; }

# section FILE START_RE END_RE — START line up to (not including) the next END.
section() { awk -v s="$2" -v e="$3" '$0 ~ s && !on {on=1; print; next} on && $0 ~ e {exit} on' "$1"; }

for skill in qa qa-only; do
  if ! "$ROOT/bin/vibe-render-skill" "$ROOT/skills/$skill/SKILL.md" "$TMP/$skill.md" >/dev/null 2>&1; then
    echo "cannot render skills/$skill/SKILL.md" >&2; exit 1
  fi
done
QA="$TMP/qa.md"; QO="$TMP/qa-only.md"

# every_line SNIPPET RENDERED [SKILL] — each non-blank snippet line appears
# whole, with {SKILL_NAME} replaced the way the renderer replaces it.
every_line() {
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    line="${line//\{SKILL_NAME\}/${3:-}}"
    grep -Fxq -- "$line" "$2" || return 1
  done < "$1"
}

echo "rubric snippet"
if [ -f "$RUBRIC" ]; then
  ok "lib/snippets/qa-health-rubric.md exists"
else
  no "lib/snippets/qa-health-rubric.md missing"
fi
checkF "the score of an unrun category is withheld" 'Accessibility has no score' "$RUBRIC"
checkF "the final score divides by the weights actually scored" '/ Σ weight' "$RUBRIC"
checkF "a score missing a category is labelled partial coverage" 'partial coverage' "$RUBRIC"
checkF "quick mode leaves Accessibility unscored" 'every quick-mode run' "$RUBRIC"
checkF "accessibility checks carry the contrast probe" 'CONTRAST_SAMPLE_OK' "$RUBRIC"
checkF "accessibility severity is graded" 'Accessibility severity' "$RUBRIC"
checkE "severity: Critical is data loss" '^- \*\*Critical\*\* — .*data loss' "$RUBRIC"
checkE "severity: High is a blocked core task with no workaround" '^- \*\*High\*\* — .*core task.*no workaround' "$RUBRIC"
checkE "severity: Medium is impaired with a workaround" '^- \*\*Medium\*\* — .*impaired.*workaround' "$RUBRIC"
checkE "severity: Low is cosmetic" '^- \*\*Low\*\* — .*[Cc]osmetic' "$RUBRIC"
checkF "counting: one issue per root cause across pages" 'root cause' "$RUBRIC"
checkF "counting: one primary category by precedence" 'Links > Accessibility > Functional > Performance > Visual > Content > UX > Console' "$RUBRIC"
checkE "counting: console errors deduped by message and source" 'message and source' "$RUBRIC"
checkE "counting: console warnings are not errors" '[Ww]arnings (are|do) not' "$RUBRIC"
checkF "counting: broken links count unique destinations" 'unique destination' "$RUBRIC"
checkF "counting: an auth redirect is not a broken link" 'auth redirect' "$RUBRIC"
checkF "console band tops out at 11+" '11+ errors' "$RUBRIC"
refuteF "console bands do not overlap at 10" '10+ errors' "$RUBRIC"
checkF "deltas only between runs that scored the same categories" 'same categories' "$RUBRIC"

echo "rubric rendered into both skills"
for skill in qa qa-only; do
  R="$TMP/$skill.md"
  if every_line "$RUBRIC" "$R"; then ok "$skill: renders every rubric line"; else no "$skill: does not render the rubric"; fi
  section "$R" '^## Health Score Rubric$' '^## ' > "$TMP/$skill-rubric.md"
  [ -s "$TMP/$skill-rubric.md" ] || no "$skill: no Health Score Rubric section"
done
if [ -s "$TMP/qa-rubric.md" ] && cmp -s "$TMP/qa-rubric.md" "$TMP/qa-only-rubric.md"; then
  ok "qa and qa-only render the same rubric section"
else
  no "qa and qa-only rubric sections differ"
fi
plain_sigma="$(grep -F 'Σ (category_score × weight)' "$QA" | grep -vF 'Σ weight' | head -1)"
if [ -z "$plain_sigma" ]; then ok "qa: no plain Σ formula"; else no "qa: plain Σ formula: $plain_sigma"; fi
refuteF "qa: console band does not overlap at 10" '10+ errors' "$QA"

echo "qa runs and honours the accessibility checks"
section "$QA" '^### Phase 4: Explore' '^### Phase 5' > "$TMP/qa-p4.md"
checkE "qa: Phase 4 checklist has the accessibility step" '^8\. \*\*Accessibility' "$TMP/qa-p4.md"
section "$QA" '^### Quick' '^### ' > "$TMP/qa-quick.md"
checkF "qa: quick mode reports Accessibility as not run" 'not run' "$TMP/qa-quick.md"
checkF "qa: quick mode labels the score partial" 'partial' "$TMP/qa-quick.md"
section "$QA" '^## Phase 9' '^## ' > "$TMP/qa-p9.md"
checkF "qa: Phase 9 compares only same-coverage scores" 'same categories' "$TMP/qa-p9.md"
section "$QA" '^\*\*Regression mode:\*\*' '^---' > "$TMP/qa-reg.md"
checkF "qa: regression delta honours the same-coverage guard" 'same categories' "$TMP/qa-reg.md"
section "$QO" '^\*\*Regression mode:\*\*' '^---' > "$TMP/qo-reg.md"
checkF "qa-only: regression delta honours the same-coverage guard" 'same categories' "$TMP/qo-reg.md"
TAX="$ROOT/skills/qa/references/issue-taxonomy.md"
crit="$(grep -E '^\| \*\*critical\*\* \|' "$TAX" | head -1 | cut -d'|' -f3)"
if printf '%s' "$crit" | grep -Fqi 'data loss' && ! printf '%s' "$crit" | grep -Fq 'core workflow'; then
  ok "taxonomy: critical means data loss, as the rubric says"
else
  no "taxonomy: critical definition disagrees with the rubric:$crit"
fi

echo "functional surfaces"
for f in "$SCOPE" "$FUNC" "$TEMPLATE"; do
  if [ -f "$f" ]; then ok "exists: ${f#"$ROOT"/}"; else no "missing: ${f#"$ROOT"/}"; fi
done
checkF "scope: browser, functional and mixed surfaces" 'SURFACE: browser|functional|mixed' "$SCOPE"
checkF "scope: no URL does not imply a web server" 'No URL does not imply a web server' "$SCOPE"
checkF "scope: isolation and ownership before the first probe" 'before the first functional probe' "$SCOPE"
checkF "functional: 2xx is not completion" '2xx is not completion' "$FUNC"
for row in 'durable effect' 'one probe per input rule' 'Authorization' 'exit code, stdout and stderr' \
           'State transitions' 'Timeout' 'Retry' 'Idempotency' 'Concurrency' 'Partial-failure recovery'; do
  checkF "functional contract map: $row" "$row" "$FUNC"
done
checkF "functional: expectation written before the probe" 'before you run it' "$FUNC"
for m in Full Quick Regression; do
  checkE "functional: $m mode" "^- \\*\\*$m\\*\\* — " "$FUNC"
done
for outcome in pass fail blocked 'not run' inconclusive; do
  checkF "template: outcome $outcome" "$outcome" "$TEMPLATE"
done
if hasE '[Hh]ealth [Ss]core|/100' "$TEMPLATE"; then no "template carries a score"; else ok "template carries no score"; fi

for skill in qa qa-only; do
  R="$TMP/$skill.md"
  if every_line "$SCOPE" "$R" "$skill" && every_line "$FUNC" "$R" "$skill"; then
    ok "$skill: renders qa-scope and qa-functional"
  else
    no "$skill: does not render qa-scope and qa-functional"
  fi
  rule12="$(grep -E '^12\. \*\*Never refuse' "$R" | head -1)"
  if printf '%s' "$rule12" | grep -Fq 'a selected browser surface'; then
    ok "$skill: rule 12 binds a selected browser surface"
  else
    no "$skill: rule 12 not scoped to a selected browser surface"
  fi
  refuteF "$skill: invocation alone no longer means browser testing" 'they are requesting browser-based testing' "$R"
  nopage="$(grep -E '^[[:space:]]*\*\*If no obvious pages/routes' "$R" | head -1)"
  if printf '%s' "$nopage" | grep -Fq 'functional surface'; then
    ok "$skill: a diff with no pages selects a functional surface"
  else
    no "$skill: a diff with no pages still falls back to a browser smoke test"
  fi
done
section "$QO" '^## Additional Rules' '^## ' > "$TMP/qo-rules.md"
checkE "qa-only: rule 11 allows read-only source discovery on a functional surface" \
  '^11\. .*functional surface.*read-only' "$TMP/qo-rules.md"

echo "shared detection snippets in qa"
checkF "qa: includes test-bootstrap" '{{include lib/snippets/test-bootstrap.md}}' "$ROOT/skills/qa/SKILL.md"
checkF "qa: includes base-branch-detect" '{{include lib/snippets/base-branch-detect.md}}' "$ROOT/skills/qa/SKILL.md"
if every_line "$ROOT/lib/snippets/base-branch-detect.md" "$QA"; then
  ok "qa: renders every base-branch-detect line"
else
  no "qa: does not render base-branch-detect"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
