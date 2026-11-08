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
#   - Both skills assemble the report from evidence (Observed, Expected,
#     Evidence, Confirmation, Hypothesis), confirm by replaying from the same
#     starting state, give quick mode a soft time budget, fall back to inline
#     fields when the template cannot be read, and print a sanitised,
#     collision-free OUTCOME_FILE path; the dead browser-attach branch is gone.
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

echo "report assembled from evidence"
for skill in qa qa-only; do
  R="$TMP/$skill.md"
  section "$R" '^### Assemble the report from evidence' '^##+ ' > "$TMP/$skill-assemble.md"
  if [ -s "$TMP/$skill-assemble.md" ]; then ok "$skill: has the assembly step"; else no "$skill: no assembly step"; fi
  for field in Observed Expected Evidence Confirmation Hypothesis; do
    checkF "$skill: assembly field $field" "**$field**" "$TMP/$skill-assemble.md"
  done
  checkF "$skill: confirmation is replayed or observed once" '`replayed`' "$TMP/$skill-assemble.md"
  checkF "$skill: an unreplayed issue says observed once" '`observed once`' "$TMP/$skill-assemble.md"
  checkF "$skill: summary lines reuse the Observed sentence verbatim" 'Observed sentence verbatim' "$TMP/$skill-assemble.md"
  checkF "$skill: a regression test asserts on the channel the bug was seen on" 'channel the bug was seen on' "$TMP/$skill-assemble.md"
  checkF "$skill: claims no command backs are scrubbed" 'no command in this run backs' "$TMP/$skill-assemble.md"
done
qo_assemble="$(grep -n '^### Assemble the report from evidence' "$QO" | head -1 | cut -d: -f1)"
qo_p6="$(grep -n '^### Phase 6' "$QO" | head -1 | cut -d: -f1)"
if [ -n "$qo_assemble" ] && [ -n "$qo_p6" ] && [ "$qo_assemble" -lt "$qo_p6" ]; then
  ok "qa-only: the report is assembled before Phase 6"
else
  no "qa-only: assembly step missing or after Phase 6"
fi
section "$QA" '^## Phase 10' '^## ' > "$TMP/qa-p10.md"
checkF "qa: Phase 10 assembles the report from evidence" 'Assemble the report from evidence' "$TMP/qa-p10.md"

echo "quick budget, replay, template fallback"
for skill in qa qa-only; do
  R="$TMP/$skill.md"
  section "$R" '^### Quick' '^### ' > "$TMP/$skill-quickmode.md"
  checkF "$skill: quick mode has a soft 3-minute budget" '3-minute' "$TMP/$skill-quickmode.md"
  checkF "$skill: quick mode reports coverage left at the cap" 'unfinished coverage' "$TMP/$skill-quickmode.md"
  refuteF "$skill: no 30-second smoke test" '30-second' "$R"
  rule2="$(grep -E '^2\. \*\*Verify before documenting' "$R" | head -1)"
  if printf '%s' "$rule2" | grep -Fq 'same starting state'; then
    ok "$skill: rule 2 replays from the same starting state"
  else
    no "$skill: rule 2 does not replay from the same starting state"
  fi
  # A replay of a submit, send or purchase on a live target repeats it.
  if printf '%s' "$rule2" | grep -Fq 'Never replay a non-idempotent action'; then
    ok "$skill: rule 2 never replays a non-idempotent action on a live target"
  else
    no "$skill: rule 2 would replay a submit, send or purchase on a live target"
  fi
  checkF "$skill: inline fields when the report template cannot be read" 'If the template cannot be read' "$R"
  bad_path="$(grep -nE 'qa-report-template\.md|issue-taxonomy\.md' "$R" | grep -vF '${CLAUDE_SKILL_DIR:-' | head -1)"
  if [ -z "$bad_path" ]; then ok "$skill: template and taxonomy reached through CLAUDE_SKILL_DIR"; else no "$skill: bare template path: $bad_path"; fi
done
section "$QA" '^### 8a' '^### ' > "$TMP/qa-8a.md"
checkF "qa: 8a replays the repro from the same starting state" 'same starting state' "$TMP/qa-8a.md"
checkF "qa: 8a does not replay a non-idempotent repro" 'non-idempotent' "$TMP/qa-8a.md"
# Value: protects=the host-path row is evidence only when the lint actually ran; fails_when=a missing or crashing lint reads as no hits; why_new=the old row passed when the binary could not run; seam=none
lint_out="$("$ROOT/bin/vibe-lint-sources" 2>&1)"
lint_hits="$(printf '%s\n' "$lint_out" | grep -E '/skills/qa(-only)?/.*host path' | head -1)"
if ! printf '%s\n' "$lint_out" | grep -q '^vibe-lint-sources: '; then
  no "host-path lint did not run: $(printf '%s' "$lint_out" | tail -1)"
elif [ -z "$lint_hits" ]; then ok "host-path lint: no hits in qa or qa-only"; else no "host-path lint: $lint_hits"; fi
refuteF "qa: no dead browser-attach branch" 'Mode: cdp' "$ROOT/skills/qa/SKILL.md"
refuteF "qa: no CDP_MODE flag" 'CDP_MODE' "$QA"

echo "functional surface coherence"
# Value: protects=the browser-only rules do not contradict the functional surface; fails_when=rule 1 demands a screenshot for a probe-transcript issue, qa-only claims it never reads source, or qa's re-test, final QA and scoring stay browser-only; why_new=the functional section landed without these call sites; seam=none
for skill in qa qa-only; do
  R="$TMP/$skill.md"
  checkF "$skill: rule 1 accepts a probe transcript on a functional surface" 'on a functional surface, the probe transcript' "$R"
  refuteF "$skill: no unconditional screenshot rule" 'Every issue needs at least one screenshot. No exceptions.' "$R"
  checkF "$skill: functional-report.md is in the output contract" 'functional-report.md' "$(printf '%s' "$R")"
  out="$(awk '/^## Output/ {f=1} f' "$R")"
  case "$out" in *'functional-report.md'*) ok "$skill: output section lists functional-report.md" ;; *) no "$skill: output section omits functional-report.md" ;; esac
  checkF "$skill: Hypothesis is optional in both skills" '**Hypothesis** — optional' "$R"
  checkF "$skill: the quick budget names its clock" 'from the first `$B goto`' "$R"
done
refuteF "qa-only: no blanket never-reads-source claim" 'This skill never reads source' "$QO"
checkF "qa-only: rule 5 names the contract-map exception" 'rule 11 allows on a functional surface' "$QO"
checkF "qa: 8d re-tests a functional row by its command and read-back" "rerun the row's exact command and read-back" "$QA"
checkF "qa: no health score on a functional-only surface" 'a functional-only surface gets no score' "$QA"
checkF "qa: Phase 9 reruns fixed functional rows" 'rerun each fixed row' "$QA"
# Value: protects=8a never overwrites a valid replayed confirmation; fails_when=an issue an earlier fix stopped reproducing is relabelled observed once; why_new=new rule; seam=none
checkF "qa: 8a keeps a replayed issue that an earlier fix resolved" 'keep its `replayed` confirmation' "$QA"
section "$QA" '^### 8b' '^### 8c' > "$TMP/qa-8b.md"
checkF "qa: 8b states the channel rule where the test is written" 'asserts on the channel the bug was seen on' "$TMP/qa-8b.md"

echo "outcome file name"
# outcome_block RENDERED — the fenced bash block that prints OUTCOME_FILE:.
outcome_block() {
  awk '/^```bash$/ {on=1; buf=""; next} on && /^```$/ {on=0; if (buf ~ /OUTCOME_FILE:/) {printf "%s", buf; exit}; next} on {buf = buf $0 "\n"}' "$1"
}
mkdir -p "$TMP/fakebin" "$TMP/repo"
printf '#!/bin/sh\necho 20260101T000000Z\n' > "$TMP/fakebin/date"
printf '#!/bin/sh\n[ -n "${FAKE_USER:-}" ] || exit 1\necho "$FAKE_USER"\n' > "$TMP/fakebin/id"
chmod +x "$TMP/fakebin/date" "$TMP/fakebin/id"
git -C "$TMP/repo" init -q -b 'feature/Weird.name' 2>/dev/null || { git -C "$TMP/repo" init -q && git -C "$TMP/repo" checkout -q -b 'feature/Weird.name'; }
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
# run_outcome SKILL FAKE_USER — run the skill's block in the scratch repo.
run_outcome() {
  (cd "$TMP/repo" && HOME="$TMP/home" VIBESTACK_HOME="$TMP/vs-$1" FAKE_USER="$2" \
    PATH="$TMP/fakebin:$PATH" bash "$TMP/$1-outcome.sh" 2>/dev/null) | sed -n 's/^OUTCOME_FILE: //p' | head -1
}
for skill in qa qa-only; do
  outcome_block "$TMP/$skill.md" > "$TMP/$skill-outcome.sh"
  if [ ! -s "$TMP/$skill-outcome.sh" ]; then no "$skill: no block prints OUTCOME_FILE:"; continue; fi
  git -C "$TMP/repo" switch -q 'feature/Weird.name' 2>/dev/null
  first="$(run_outcome "$skill" 'j.doe')"
  if [ "$(basename "$first")" = 'j-doe-feature-Weird-name-test-outcome-20260101T000000Z.md' ]; then
    ok "$skill: user and branch sanitised, UTC stamp"
  else
    no "$skill: outcome name not sanitised: ${first:-<none>}"
  fi
  # Value: protects=two runs in the same second never share an outcome file; fails_when=the name is checked but not reserved before it is printed; why_new=the collision row below pre-creates the file itself; seam=none
  [ -n "$first" ] && [ -e "$first" ] && ok "$skill: the printed outcome file is reserved (created) before use" \
    || no "$skill: outcome file printed but not reserved: ${first:-<none>}"
  [ -n "$first" ] && mkdir -p "$(dirname "$first")" && : > "$first"
  second="$(run_outcome "$skill" 'j.doe')"
  if [ -n "$first" ] && [ "$second" = "${first%.md}-2.md" ]; then
    ok "$skill: a name already taken gets a suffix"
  else
    no "$skill: collision not suffixed: ${second:-<none>}"
  fi
  git -C "$TMP/repo" switch -q --detach 2>/dev/null
  third="$(run_outcome "$skill" '')"
  case "$(basename "${third:-x}")" in
    unknown-user-detached-test-outcome-20260101T000000Z.md) ok "$skill: unknown-user and detached fallbacks" ;;
    *) no "$skill: fallbacks missing: ${third:-<none>}" ;;
  esac
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
