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
#   - performance findings state their scale and never invent benchmarks, and a
#     hot path with no budget or measurement step is a finding;
#   - the Design Doc Check prefers the repo's DESIGN.md and uses a CEO plan only
#     when it names the current branch (run against a scratch store, for eng and
#     autoplan);
#   - Step 0 ends in a REALITY line, the architecture section carries the
#     release & rollback check, and lane briefs name their interfaces;
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

perf_sec="$(sed -n "${perf:-1},\$p" "$ENG" | sed -n '1,/^\*\*STOP\.\*\*/p')"
if printf '%s' "$perf_sec" | grep -qF "no budget source or measurement step named is a finding"; then
  ok "a hot path with no budget or measurement step is a finding"
else
  no "a hot path with no budget or measurement step is a finding"
fi

echo "design context"
# The Design Doc Check block runs against a scratch store and repo: the repo's
# DESIGN.md wins over an older per-user doc, and a CEO plan is used only when
# its Branch: line names the current branch.
design_block() {
  python3 -I - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
h = re.search(r"^#{2,3} Design Doc Check\n", text, re.M)
m = re.search(r"```bash\n(.*?)\n```", text[h.end():], re.S) if h else None
sys.stdout.write(m.group(1) + "\n" if m else "")
PY
}
VB="$TMP/vb"; DREPO="$TMP/drepo"
mkdir -p "$VB/bin" "$VB/projects/proj/ceo-plans" "$DREPO"
DREPO="$(cd "$DREPO" && pwd -P)"  # git prints the resolved path (/private/var on macOS)
printf '#!/usr/bin/env bash\necho SLUG=proj\n' > "$VB/bin/vibe-slug"; chmod +x "$VB/bin/vibe-slug"
git -C "$DREPO" -c init.defaultBranch=feat/ctx init -q
git -C "$DREPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
printf '# store doc\n' > "$VB/projects/proj/u-feat-ctx-design-1.md"
touch -t 202601010000 "$VB/projects/proj/u-feat-ctx-design-1.md"
printf '# repo doc\n' > "$DREPO/DESIGN.md"
printf -- '# CEO Plan: x\nBranch: feat/ctx | Mode: HOLD SCOPE\n' > "$VB/projects/proj/ceo-plans/2026-01-01-x.md"
touch -t 202601010000 "$VB/projects/proj/ceo-plans/2026-01-01-x.md"
run_design() {  # FILE -> block output
  local block; block="$(design_block "$1")"
  [ -n "$block" ] || { echo "NO_BLOCK"; return; }
  (cd "$DREPO" && HOME="$TMP" VIBESTACK_HOME="$VB" bash -c "$block" 2>&1) || true
}
for f in "$ENG" "$AUTO"; do
  name="$(basename "$(dirname "$f")")"; [ "$f" = "$ENG" ] && name="plan-eng-review"
  out="$(run_design "$f")"
  printf '%s\n' "$out" | grep -qxF "Design doc found: $DREPO/DESIGN.md" \
    && ok "$name: repo DESIGN.md wins over an older store doc" || no "$name: repo DESIGN.md wins over an older store doc: '$out'"
  printf '%s\n' "$out" | grep -qxF "CEO plan found: $VB/projects/proj/ceo-plans/2026-01-01-x.md" \
    && ok "$name: same-branch CEO plan is found" || no "$name: same-branch CEO plan is found: '$out'"
done
# A newer plan from another branch must not hide this branch's older plan.
printf -- '# CEO Plan: y\nBranch: other | Mode: HOLD SCOPE\n' > "$VB/projects/proj/ceo-plans/2026-02-01-y.md"
for f in "$ENG" "$AUTO"; do
  name="plan-eng-review"; [ "$f" = "$AUTO" ] && name="autoplan"
  out="$(run_design "$f")"
  printf '%s\n' "$out" | grep -qxF "CEO plan found: $VB/projects/proj/ceo-plans/2026-01-01-x.md" \
    && ! printf '%s\n' "$out" | grep -qF "CEO plan from another branch" \
    && ok "$name: same-branch CEO plan wins over a newer other-branch plan" || no "$name: same-branch CEO plan wins over a newer other-branch plan: '$out'"
done
rm "$VB/projects/proj/ceo-plans/2026-01-01-x.md"
for f in "$ENG" "$AUTO"; do
  name="plan-eng-review"; [ "$f" = "$AUTO" ] && name="autoplan"
  out="$(run_design "$f")"
  printf '%s\n' "$out" | grep -qxF "CEO plan from another branch (other): $VB/projects/proj/ceo-plans/2026-02-01-y.md" \
    && ok "$name: another branch's CEO plan is labelled, not used" || no "$name: another branch's CEO plan is labelled: '$out'"
done
has "$ENG" "ask before using it" "eng asks before using another branch's CEO plan"
has "$ENG" "Scope Decisions" "eng reads the CEO plan's scope decisions"

echo "reality check"
reality=$(line_of "$ENG" "#### Reality check")
sec1=$(line_of "$ENG" "### 1. Architecture review")
if [ "${reality:-0}" -gt "${step0:-0}" ] && [ "${reality:-0}" -lt "${sec1:-0}" ]; then
  ok "reality check sits in Step 0"
else
  no "reality check sits in Step 0 (reality=${reality:-0}, step0=${step0:-0}, sec1=${sec1:-0})"
fi
has "$ENG" '`REALITY: surface-check pass`' "reality check ends in a REALITY pass line"
has "$ENG" '`REALITY: surface-check finding <summary> <file:line|sha>`' "reality check ends in a REALITY finding line"
has "$ENG" "- Reality: pass / finding" "completion summary reports the reality check"

echo "completeness and data model"
lacks "$ENG" "Boil the lake." "completeness check drops boil-the-lake"
has   "$ENG" "**Completeness check:** Does the plan cover the stated requirement" "completeness check is about coverage"
has   "$ENG" "* Data model: storage follows the queries" "data-model preference listed"

echo "release and rollback"
rr="$(sed -n '/^\*\*Release & rollback\*\*/,/^\*\*STOP\.\*\*/p' "$ENG")"
for item in "Deploy order" "Compatibility window" "Rollback command" "Data recovery" "One-way steps"; do
  printf '%s' "$rr" | grep -qF "**$item**" && ok "release check names $item" || no "release check names $item"
done
printf '%s' "$rr" | grep -qF "is an unresolved decision" && ok "a missing release item is an unresolved decision" \
                                                        || no "a missing release item is an unresolved decision"
printf '%s' "$rr" | grep -qF "code_blast" && ok "release check cites code_blast" || no "release check cites code_blast"
rr_at=$(line_of "$ENG" "**Release & rollback**")
sec2=$(line_of "$ENG" "### 2. Code quality review")
if [ "${rr_at:-0}" -gt "${sec1:-0}" ] && [ "${rr_at:-0}" -lt "${sec2:-0}" ]; then
  ok "release check is part of the architecture section"
else
  no "release check is part of the architecture section (at=${rr_at:-0})"
fi

echo "lane briefs and TODOs"
has "$ENG" "   - **Interfaces** — " "cold-start brief names interfaces"
has "$ENG" "interface names agree across lanes" "completion summary checks interface names"
has "$ENG" "**C)** Build it now in this PR instead of deferring (records accepted scope; edits no product code)" \
    "build-it-now records scope without editing code"

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
