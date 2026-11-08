#!/usr/bin/env bash
# test-devex-boomerang.sh — /devex-review reads the /plan-devex-review baseline,
# and drives the browser under the look-not-act rules.
#
# Covers:
#   - bin/vibe-review-read --skill X --json returns X's full entries (pass_scores
#     and all), newest first, and nothing from other skills;
#   - the Boomerang Baseline block in the rendered /devex-review, executed
#     against a fixture log, prints the plan's pass_scores — a grep over the
#     pretty-printed JSON prints only the "skill" line and fails here;
#   - --any-branch --skill returns the newest entry across every branch log of
#     the project (slash branches included) with its branch, and the devex
#     baseline block uses it, so a plan reviewed on another branch is found;
#   - /plan-devex-review's DX Trend Check uses the same read;
#   - /devex-review states the browser rules: LOCAL vs NON-LOCAL consent before
#     submitting, same-origin browsing, no credential typing, untrusted pages.
#
# Usage: test/test-devex-boomerang.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VIBESTACK_HOME="$TMP/home"
export PYTHONDONTWRITEBYTECODE=1

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -Eq -- "$1" "$2"; }
check() { if has "$2" "$3"; then ok "$1"; else no "$1"; fi; }
refute() { if has "$2" "$3"; then no "$1: $(grep -E -- "$2" "$3" | head -1)"; else ok "$1"; fi; }

render() {
  local out="$TMP/$1.md"
  "$BIN/vibe-render-skill" "$ROOT/skills/$1/SKILL.md" "$out" >/dev/null 2>&1 \
    || { echo "cannot render skills/$1/SKILL.md" >&2; exit 1; }
  printf '%s\n' "$out"
}
section() { awk -v s="$2" -v e="$3" '$0 ~ s {on=1} on && $0 ~ e && !($0 ~ s) {on=0} on' "$1"; }
first_bash() { awk '/^```bash/ && !done {on=1; next} /^```/ && on {on=0; done=1} on' "$1"; }

# ── fixture repo + review log ────────────────────────────────────────────────
REPO="$TMP/repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q -b feat && git config user.email t@example.com \
  && git config user.name t && echo a > a && git add a && git commit -qm init)
SLUG="$(cd "$REPO" && VIBESTACK_SLUG_NO_MIGRATE=1 "$BIN/vibe-slug" | sed -n 's/^SLUG=//p')"
[ -n "$SLUG" ] || { echo "cannot resolve fixture slug" >&2; exit 1; }
LOGDIR="$VIBESTACK_HOME/projects/$SLUG"
mkdir -p "$LOGDIR"
{
  echo '{"skill":"plan-devex-review","timestamp":"2026-01-01T00:00:00Z","status":"clean","overall_score":5,"tthw_target":"9 min","pass_scores":{"getting_started":4,"api_design":5,"errors":5,"docs":5,"upgrade":5,"dev_env":5,"community":5,"measurement":5}}'
  echo '{"skill":"review","timestamp":"2026-01-02T00:00:00Z","status":"clean"}'
  echo '{"skill":"plan-devex-review","timestamp":"2026-01-03T00:00:00Z","status":"clean","overall_score":7,"tthw_target":"3 min","pass_scores":{"getting_started":8,"api_design":7,"errors":6,"docs":7,"upgrade":6,"dev_env":7,"community":5,"measurement":4}}'
} > "$LOGDIR/feat-reviews.jsonl"

echo "vibe-review-read --skill --json"
OUT="$(cd "$REPO" && "$BIN/vibe-review-read" --skill plan-devex-review --json)"
SHAPE="$(printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len(rows), {r["skill"] for r in rows} == {"plan-devex-review"},
      rows[0]["timestamp"], rows[0]["pass_scores"]["getting_started"], rows[0]["tthw_target"])
' 2>&1)"
[ "$SHAPE" = "2 True 2026-01-03T00:00:00Z 8 3 min" ] \
  && ok "returns only that skill's entries, newest first, with pass_scores" \
  || no "unexpected --skill --json result: $SHAPE"
ALL="$(cd "$REPO" && "$BIN/vibe-review-read" --json | python3 -c 'import json,sys; print([r["timestamp"][:10] for r in json.load(sys.stdin)])')"
[ "$ALL" = "['2026-01-01', '2026-01-02', '2026-01-03']" ] \
  && ok "unfiltered --json keeps log order" || no "unfiltered order changed: $ALL"
NONE="$(cd "$REPO" && "$BIN/vibe-review-read" --skill devex-review --json | tr -d '[:space:]')"
[ "$NONE" = "[]" ] && ok "a skill with no entries reads as []" || no "empty skill printed: $NONE"

# ── /devex-review boomerang baseline, executed ───────────────────────────────
echo "devex-review: boomerang baseline"
DX="$(render devex-review)"
BASE="$TMP/dx-base.md"
section "$DX" '^### Boomerang Baseline' '^## Step 1:' > "$BASE"
[ -s "$BASE" ] || { echo "Boomerang Baseline not found in devex-review" >&2; exit 1; }
first_bash "$BASE" | sed -e "s|\${VIBESTACK_HOME:-\$HOME/.vibestack}/bin/|$BIN/|g" -e "s|~/.vibestack/bin/|$BIN/|g" > "$TMP/base.sh"
BOUT="$(cd "$REPO" && bash "$TMP/base.sh" 2>&1)"
printf '%s' "$BOUT" | grep -q '"getting_started": 8' \
  && ok "the baseline block prints the plan's pass_scores" \
  || no "the baseline block lost the plan scores: $(printf '%s' "$BOUT" | head -3)"
printf '%s' "$BOUT" | grep -q '"tthw_target": "3 min"' \
  && ok "the baseline block prints the TTHW target" || no "no tthw_target in baseline output"
check "the comparison maps pass_scores to the Plan Score column" 'pass_scores' \
  <(section "$DX" '^## Boomerang Comparison' '^## ')

echo "devex-review: a baseline from another branch"
# The plan was reviewed on a feature branch; the audit runs on a branch with no log.
mkdir -p "$LOGDIR/feature"
echo '{"skill":"plan-devex-review","timestamp":"2026-02-01T00:00:00Z","status":"clean","branch":"feature/plan","overall_score":9,"tthw_target":"2 min","pass_scores":{"getting_started":9}}' \
  > "$LOGDIR/feature/plan-reviews.jsonl"
echo '{"skill":"plan-devex-review","timestamp":"2026-01-15T00:00:00Z","status":"clean","pass_scores":{"getting_started":6}}' \
  > "$LOGDIR/old-reviews.jsonl"
(cd "$REPO" && git checkout -q -b audit)
SAME="$(cd "$REPO" && "$BIN/vibe-review-read" --skill plan-devex-review --json | tr -d '[:space:]')"
[ "$SAME" = "NO_REVIEWS" ] && ok "the per-branch read still sees only this branch" || no "per-branch read changed: $SAME"
ANY="$(cd "$REPO" && "$BIN/vibe-review-read" --any-branch --skill plan-devex-review --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len(rows), rows[0]["branch"], rows[0]["pass_scores"]["getting_started"])' 2>&1)"
[ "$ANY" = "1 feature/plan 9" ] && ok "--any-branch returns the newest entry across branch logs, with its branch" \
  || no "--any-branch: $ANY"
BOUT2="$(cd "$REPO" && bash "$TMP/base.sh" 2>&1)"
printf '%s' "$BOUT2" | grep -q '"getting_started": 9' && printf '%s' "$BOUT2" | grep -q '"branch": "feature/plan"' \
  && ok "the baseline block finds a plan reviewed on another branch and names it" \
  || no "baseline from another branch: $(printf '%s' "$BOUT2" | head -4)"
printf '%s' "$BOUT2" | grep -q '^CURRENT_BRANCH: audit$' && ok "the baseline block prints the current branch to compare" \
  || no "no CURRENT_BRANCH line"
NONE2="$(cd "$REPO" && "$BIN/vibe-review-read" --any-branch --skill nothing-here --json | tr -d '[:space:]')"
[ "$NONE2" = "[]" ] && ok "--any-branch with no entries reads as []" || no "--any-branch empty: $NONE2"
(cd "$REPO" && "$BIN/vibe-review-read" --any-branch >/dev/null 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--any-branch without --skill is a usage error" || no "--any-branch without --skill exit $rc"
(cd "$REPO" && git checkout -q feat)

echo "plan-devex-review: DX trend check"
PDX="$(render plan-devex-review)"
TREND="$TMP/pdx-trend.md"
section "$PDX" '^### DX Trend Check' '^### Pass 1' > "$TREND"
[ -s "$TREND" ] || { echo "DX Trend Check not found in plan-devex-review" >&2; exit 1; }
first_bash "$TREND" | sed -e "s|\${VIBESTACK_HOME:-\$HOME/.vibestack}/bin/|$BIN/|g" -e "s|~/.vibestack/bin/|$BIN/|g" > "$TMP/trend.sh"
TOUT="$(cd "$REPO" && bash "$TMP/trend.sh" 2>&1)"
printf '%s' "$TOUT" | grep -q '"getting_started": 4' \
  && ok "the trend block prints prior pass_scores" || no "the trend block lost prior scores"

for f in "$DX" "$PDX"; do
  refute "$(basename "$f" .md): no grep over pretty-printed review JSON" \
    'vibe-review-read[^|]*\|[[:space:]]*grep' "$f"
done

# Codex takes web search as config; the old feature toggle is not a flag it accepts.
for f in "$DX" "$PDX"; do
  refute "$(basename "$f" .md): no --enable web_search_cached" '--enable web_search_cached' "$f"
done

# ── /plan-devex-review: ask before editing ───────────────────────────────────
echo "plan-devex-review: approval before plan edits"
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
RATE="$TMP/pdx-rate.md"; section "$PDX" '^## The 0-10 Rating Method' '^## Review Sections' > "$RATE"
[ -s "$RATE" ] || { echo "Rating Method not found in plan-devex-review" >&2; exit 1; }
ASK_LN="$(grep -n 'AskUserQuestion' "$RATE" | head -1 | cut -d: -f1)"
FIX_LN="$(grep -nE '^[0-9]+\. (\*\*)?(Fix|Apply|Edit)' "$RATE" | head -1 | cut -d: -f1)"
[ -n "$ASK_LN" ] && { [ -z "$FIX_LN" ] || [ "$FIX_LN" -gt "$ASK_LN" ]; } \
  && ok "no fix or plan edit precedes the AskUserQuestion step" \
  || no "rating method edits before asking (fix line ${FIX_LN:-none}, ask line ${ASK_LN:-none})"
check "only approved scope is applied" 'only (the )?approved scope' <(flat "$RATE")
check "never adds scope to reach a 10" '[Nn]ever add scope to reach (a )?10' <(flat "$RATE")
check "decisions carry across passes" 'Carry decisions across passes' "$RATE"
refute "no fix-until-10 loop" 'until 10' "$RATE"
P1="$TMP/pdx-p1.md"; section "$PDX" '^### Pass 1:' '^### Pass 2:' > "$P1"
refute "Pass 1 does not write the fix before asking" 'FIX TO 10' "$P1"
G0="$TMP/pdx-0g.md"; section "$PDX" '^### 0G\.' '^## The 0-10 Rating Method' > "$G0"
refute "0G has no bulk fix-everything option" 'fix every confusion point' "$G0"
check "0G asks once per evidenced confusion point" 'one AskUserQuestion per evidenced confusion point' <(flat "$G0")
MODES="$TMP/pdx-modes.md"; section "$PDX" '^## Mode Quick Reference' '^## Formatting' > "$MODES"
check "TRIAGE runs all 8 passes for blockers and error caps" 'All 8, blockers only \(<5\) plus every error-contract cap' <(flat "$MODES")
refute "TRIAGE no longer cuts to two passes" 'Pass 1 \+ 3 only' "$MODES"
refute "TRIAGE journey is not cut to two stages" 'Install \+ Hello' "$MODES"
F0="$TMP/pdx-0f.md"; section "$PDX" '^### 0F\.' '^### 0G\.' > "$F0"
refute "0F TRIAGE does not skip journey stages" 'Only trace Install and Hello World' "$F0"

echo "plan-devex-review: agent-ready error rubric"
HOF="$ROOT/skills/plan-devex-review/dx-hall-of-fame.md"
H3="$TMP/hof-p3.md"; section "$HOF" '^## Pass 3' '^## Pass 4' > "$H3"
[ -s "$H3" ] || { echo "Pass 3 not found in dx-hall-of-fame.md" >&2; exit 1; }
n_items="$(grep -oE '^[1-8]\. \*\*(What|Fix|Recovery|Code|Context|Trace|Redaction|Channel)\*\*' "$H3" | sort -u | wc -l | tr -d ' ')"
[ "$n_items" = 8 ] && ok "Pass 3 reference lists the 8-item error contract" || no "error contract items found: $n_items/8"
check "error contract defines CAP4" '\*\*CAP4\*\*' "$H3"
check "error contract defines CAP6" '\*\*CAP6\*\*' "$H3"
check "failure classes are named" '[Ff]ailure class' "$H3"
check "surface rules are named" '[Ss]urface' "$H3"
check "one worked CLI example" '^\$ ' "$H3"
refute "no external doc URL in the error reference" 'https?://' "$H3"
PRIN="$TMP/pdx-prin.md"; section "$PDX" '^## DX First Principles' '^## The Seven' > "$PRIN"
check "principle 9 covers agent-readable errors" '^9\. \*\*' "$PRIN"
check "0A offers the AI coding agent persona" 'AI coding agent' <(section "$PDX" '^### 0A\.' '^### 0B\.')
check "agent-reader cognitive pattern" '^11\. \*\*Agent reader' <(section "$PDX" '^## Cognitive Patterns' '^## DX Scoring')
P3="$TMP/pdx-p3.md"; section "$PDX" '^### Pass 3:' '^### Pass 4:' > "$P3"
check "Pass 3 fills an ERROR PATH MATRIX" 'ERROR PATH MATRIX' "$P3"
check "the matrix carries an unexpected-failure row" '[Uu]nexpected failure' "$P3"
check "TRIAGE always reports CAP4" 'TRIAGE always reports CAP4' <(flat "$P3")
check "implementation checklist has the agent-ready contract row" 'agent-ready error contract' \
  <(section "$PDX" '^### DX Implementation Checklist' '^### Unresolved')
LOGB="$TMP/pdx-log.sh"; first_bash <(section "$PDX" '^## Review Log' '^## ') > "$LOGB"
LOGJSON="$(sed -n "s/^.*vibe-review-log\" '\(.*\)'\$/\1/p" "$LOGB" | sed 's/:N\([,}]\)/:0\1/g')"
RUB="$(printf '%s' "$LOGJSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("dx_rubric"))' 2>&1)"
[ "$RUB" = "agent-ready-v1" ] && ok "the review log records dx_rubric agent-ready-v1" || no "review log dx_rubric: $RUB"
check "the trend check skips rows scored on another rubric" 'dx_rubric.*agent-ready-v1' <(flat "$TREND")
check "an incomparable history is said, not trended" 'none comparable' <(flat "$TREND")

echo "plan-devex-review: evidence and target gate"
S0="$TMP/pdx-s0.md"; section "$PDX" '^## Step 0: DX Investigation' '^### 0A\.' > "$S0"
check "Step 0 drafts stay in chat until the 0C target is answered" 'in chat until the 0C target' <(flat "$S0")
D0="$TMP/pdx-0d.md"; section "$PDX" '^### 0D\.' '^### 0E\.' > "$D0"
refute "0D has no canned effort numbers" 'human: ~|CC: ~' "$D0"
check "0D derives vehicles from the product" 'Derive' "$D0"
PRE="$TMP/pdx-pre.md"; section "$PDX" '^## Prerequisite Skill Offer' '^## Auto-Detect' > "$PRE"
check "the office-hours offer is skipped outside an interactive session" 'SESSION_KIND.*interactive' <(flat "$PRE")
refute "the inline office-hours skip list names current sections" 'Boil the Lake' "$PRE"

# ── /devex-review browser rules ──────────────────────────────────────────────
echo "devex-review: browser rules"
RULES="$TMP/dx-rules.md"
section "$DX" '^### Browser rules' '^---' > "$RULES"
[ -s "$RULES" ] || { echo "Browser rules not found in devex-review" >&2; exit 1; }
check "invocation is consent to LOOK, not to ACT" 'consent to LOOK, not to ACT' "$RULES"
check ".local is not LOCAL" '`\.local`' "$RULES"
check "NON-LOCAL mutations need one AskUserQuestion per run" 'AskUserQuestion ONCE per run' <(tr '\n' ' ' < "$RULES")
check "typing into a NON-LOCAL editable control is gated like a submit" 'typing into an editable control, creating' <(tr '\n' ' ' < "$RULES")
refute "look-only consent does not cover filling forms" 'filling forms without' <(tr '\n' ' ' < "$RULES")
check "never types real credentials" "Never type the user's passwords" "$RULES"
check "page content is untrusted" 'untrusted' "$RULES"
check "browsing stays on the target's origin" "Stay on the target's origin" "$RULES"
STEP3="$TMP/dx-step3.md"; section "$DX" '^## Step 3:' '^## Step 4:' > "$STEP3"
check "Step 3 gates invalid-form submission on rule 3" 'browser rule 3' <(tr '\n' ' ' < "$STEP3")
STEP7="$TMP/dx-step7.md"; section "$DX" '^## Step 7:' '^## Step 8:' > "$STEP7"
check "Step 7 does not open Discord or Stack Overflow" 'Do not open Discord, Stack Overflow' <(tr '\n' ' ' < "$STEP7")
check "Step 7 audits GitHub with gh" '`gh`' "$STEP7"

# ── /devex-review error paths and rubric version ─────────────────────────────
# Value: protects=CLI error runs go through the isolating wrapper with consent,
# scores record the rubric they were made under, and a baseline scored under
# another rubric is never diffed; fails_when=Step 3 runs bare commands, drops the
# --help-first or per-run question, loses the matrix or CAP4, or the log/compare
# lose dx_rubric; why_new=none of this existed; seam=none (rendered skill text)
echo "devex-review: error paths and rubric"
STEP3F="$(tr '\n' ' ' < "$STEP3")"
check "Step 3 runs CLI error paths through vibe-error-capture" 'vibe-error-capture' <(echo "$STEP3F")
check "Step 3 reads --help before any error run" '`--help` first' <(echo "$STEP3F")
check "unapproved runs only for forms help says are rejected before work" 'rejected before any work' <(echo "$STEP3F")
check "every other run gets its own AskUserQuestion" 'one AskUserQuestion per run' <(echo "$STEP3F")
check "--pass-env only with --approved" '--approved' <(echo "$STEP3F")
check "Step 3 fills an ERROR PATH MATRIX" 'ERROR PATH MATRIX' "$STEP3"
check "the matrix covers an unexpected failure" 'Unexpected failure' "$STEP3"
check "exit 0 on an error path caps the dimension at 4" 'exits? 0.*CAP4' <(echo "$STEP3F")
check "a secret in error output is a finding" 'secret_findings' <(echo "$STEP3F")
LOG="$TMP/dx-log.md"; section "$DX" '^## Review Log' '^## Next Steps' > "$LOG"
check "the review log records the rubric version" '"dx_rubric":"agent-ready-v1"' "$LOG"
CMP="$TMP/dx-cmp.md"; section "$DX" '^## Boomerang Comparison' '^## Review Log' > "$CMP"
check "the comparison reads the baseline's dx_rubric" 'dx_rubric' "$CMP"
check "a different rubric prints 'rubric changed, not comparable'" 'rubric changed, not comparable' <(tr '\n' ' ' < "$CMP")
PDX_RUBRIC="$(grep -oE 'dx_rubric[^a-z]+[a-z0-9-]+-v[0-9]+' "$PDX" | grep -oE '[a-z0-9-]+-v[0-9]+$' | sort -u)"
if [ -z "$PDX_RUBRIC" ]; then ok "plan-devex-review names no rubric yet (nothing to match)"
elif [ "$PDX_RUBRIC" = "agent-ready-v1" ]; then ok "both skills log the same rubric name"
else no "plan-devex-review logs rubric '$PDX_RUBRIC', devex-review compares agent-ready-v1"; fi
grep -qxF '{{include lib/snippets/base-branch-detect.md}}' "$ROOT/skills/devex-review/SKILL.md" \
  && ok "base branch detection comes from the shared snippet" || no "devex-review inlines its own base-branch fallback"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
