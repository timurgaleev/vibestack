#!/usr/bin/env bash
# test-plan-eng-review-rubric.sh — review rules in /plan-eng-review and the
# shared Implementation Tasks snippet.
#
# Covers:
#   - shared code is judged by a caller-proving rubric, never "flag repetition
#     aggressively";
#   - the complexity gate asks feature cuts one at a time, then always asks a
#     same-features structure question;
#   - the retrospective git-history check runs before the scope challenge and
#     names concrete commands;
#   - performance findings state their scale and never invent benchmarks;
#   - task effort ratios are written out in the snippet every plan review renders,
#     instead of pointing at a table that does not exist.
#
# Usage: test/test-plan-eng-review-rubric.sh [repo-root]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

for s in plan-eng-review plan-ceo-review plan-design-review plan-devex-review; do
  if ! VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/$s/SKILL.md" "$TMP/$s.md" >/dev/null 2>&1; then
    no "$s renders"
  fi
done
ENG="$TMP/plan-eng-review.md"
[ -s "$ENG" ] || { echo "plan-eng-review did not render" >&2; exit 1; }

# has FILE FIXED-STRING LABEL / lacks FILE FIXED-STRING LABEL
has()   { if grep -qF -- "$2" "$1"; then ok "$3"; else no "$3"; fi; }
lacks() { if grep -qF -- "$2" "$1"; then no "$3"; else ok "$3"; fi; }
# line_of FILE FIXED-STRING -> first line number, or 0
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1 || true; }

echo "shared-code rubric"
lacks "$ENG" "flag repetition aggressively" "no blanket repetition flagging in preferences"
lacks "$ENG" "DRY violations—be aggressive" "code quality review drops aggressive DRY"
has   "$ENG" "#### Shared-code rubric" "rubric heading present"
has   "$ENG" "At least two verified first-party source locations" "rubric requires two verified callers"
has   "$ENG" "Savings = removed" "rubric requires line accounting"
has   "$ENG" "**Reject incompatible contracts.**" "rubric rejects incompatible contracts"
# The CEO review and autoplan judge shared code by the same rubric, so the
# three reviews cannot hand the user contradictory advice.
CEO="$TMP/plan-ceo-review.md"
has   "$CEO" "#### Shared-code rubric" "CEO review renders the same rubric"
has   "$CEO" "At least two verified first-party source locations" "CEO rubric requires two verified callers"
lacks "$CEO" "flag repetition aggressively" "CEO preferences drop blanket repetition flagging"
lacks "$CEO" "DRY violations. Be aggressive" "CEO code quality section drops aggressive DRY"
AUTO="$SRC/skills/autoplan/SKILL.md"
lacks "$AUTO" "**DRY** — Duplicates existing functionality? Reject." "autoplan P4 no longer rejects on similarity alone"
lacks "$AUTO" "Identify DRY violations" "autoplan eng phase uses the rubric"

echo "complexity gate"
lacks "$ENG" "ask whether to reduce or proceed as-is" "single reduce-or-proceed question gone"
has   "$ENG" "**Feature cuts, one at a time.**" "feature cuts asked separately"
has   "$ENG" "**Structure question, always.**" "structure question always asked"
has   "$ENG" '`Original arrangement`' "original arrangement option"
has   "$ENG" '`Smaller arrangement`' "smaller arrangement option"

echo "retrospective check"
retro=$(line_of "$ENG" "### Retrospective check")
step0=$(line_of "$ENG" "### Step 0: Scope Challenge")
summary=$(line_of "$ENG" "### Completion summary")
if [ "${retro:-0}" -gt 0 ] && [ "${step0:-0}" -gt 0 ] && [ "$retro" -lt "$step0" ]; then
  ok "retrospective check precedes the scope challenge"
else
  no "retrospective check precedes the scope challenge (retro=${retro:-0}, step0=${step0:-0})"
fi
lacks "$ENG" "## Retrospective learning" "no retrospective section after the review"
has   "$ENG" "git log --oneline -20 -- <paths>" "history command named"
has   "$ENG" "git log --grep=revert -i --oneline -20" "revert command named and bounded"
has   "$ENG" '`not available`' "future paths marked not available"
[ "${summary:-0}" -gt "${retro:-0}" ] && ok "completion summary still follows" || no "completion summary still follows"

echo "performance review"
perf=$(line_of "$ENG" "### 4. Performance review")
if [ "${perf:-0}" -gt 0 ] && sed -n "${perf},\$p" "$ENG" | sed -n '1,/^\*\*STOP\.\*\*/p' | grep -qF "never invent benchmarks"; then
  ok "performance section forbids invented benchmarks"
else
  no "performance section forbids invented benchmarks"
fi
has "$ENG" 'mark it `scale unknown`' "performance findings state scale"

echo "task effort ratios"
SNIP="$SRC/lib/snippets/tasks-section-emit.md"
lacks "$SNIP" "AI-compression table from CLAUDE.md" "no dangling table reference"
has   "$SNIP" "scaffolding ~100x" "ratios inlined in the snippet"
has   "$SNIP" "state the ratio you assumed" "assumption must be stated"
for s in plan-eng-review plan-ceo-review plan-design-review plan-devex-review; do
  [ -s "$TMP/$s.md" ] && has "$TMP/$s.md" "scaffolding ~100x" "$s renders the effort ratios"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
