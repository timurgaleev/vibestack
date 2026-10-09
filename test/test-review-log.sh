#!/usr/bin/env bash
# test-review-log.sh — bin/vibe-review-log tree binding and honest-status guards,
# plus the /review contracts that feed it.
#
# Covers:
#   - --snapshot fingerprints tracked AND non-ignored untracked content, ignores
#     .gitignore'd files, is unchanged by committing the same bytes, never
#     touches the real index, and exits 2 with empty stdout outside a work tree;
#   - every logged entry carries the logger's own `tree` (a caller value is
#     overwritten);
#   - a `clean` status is refused when start_tree != tree, the tree cannot be
#     snapshotted, completed is false or converged is false, and nothing is
#     written; non-clean statuses still log;
#   - skills/review/SKILL.md: a failed base fetch is not "nothing to review",
#     untracked files reach every reviewer, failed reviewers mean incomplete
#     coverage, and fixes get a bounded re-review whose record carries the
#     start snapshot;
#   - skills/ship/SKILL.md: the dashboard clears only a review of the tree
#     being shipped.
#
# Usage: test/test-review-log.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
BIN="$SRC/bin"
SK="$SRC/skills/review/SKILL.md"
[ -x "$BIN/vibe-review-log" ] && [ -f "$SK" ] || { echo "not a repo root: $SRC" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VIBESTACK_HOME="$TMP/home"
export PYTHONDONTWRITEBYTECODE=1

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

REPO="$TMP/repo"
mkdir -p "$REPO"
(
  cd "$REPO" && git init -q -b feat && git config user.email t@example.com &&
  git config user.name t && printf 'ignored.log\n' > .gitignore &&
  printf 'a\n' > a.txt && git add . && git commit -qm init
)
snap() { (cd "$REPO" && "$BIN/vibe-review-log" --snapshot); }
log() { (cd "$REPO" && "$BIN/vibe-review-log" "$1"); }
LOGF() { find "$VIBESTACK_HOME/projects" -name '*-reviews.jsonl' 2>/dev/null | head -1; }
lines() { f=$(LOGF); [ -n "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0; }

echo "snapshot"
S0=$(snap)
if printf '%s' "$S0" | grep -Eq '^[0-9a-f]{12}$'; then ok "12-hex snapshot"; else no "snapshot shape: '$S0'"; fi
printf 'new\n' > "$REPO/new.txt"
S1=$(snap)
[ "$S1" != "$S0" ] && ok "untracked file moves the snapshot" || no "untracked file ignored by snapshot"
printf 'x\n' > "$REPO/ignored.log"
chk "gitignored file does not move it" "$(snap)" "$S1"
chk "real index untouched" "$(cd "$REPO" && git diff --cached --name-only)" ""
chk "new file still untracked" "$(cd "$REPO" && git ls-files --others --exclude-standard)" "new.txt"
(cd "$REPO" && git add new.txt && git commit -qm add)
chk "committing the same bytes keeps the snapshot" "$(snap)" "$S1"
printf 'edit\n' >> "$REPO/a.txt"
S2=$(snap)
[ "$S2" != "$S1" ] && ok "tracked edit moves the snapshot" || no "tracked edit ignored"
OUT=$(cd "$TMP" && "$BIN/vibe-review-log" --snapshot 2>/dev/null); RC=$?
chk "exit 2 outside a work tree" "$RC" "2"
chk "empty stdout outside a work tree" "$OUT" ""

echo "logging"
log '{"skill":"review","status":"clean","start_tree":"'"$S2"'","completed":true,"converged":true,"tree":"forged"}' >/dev/null
chk "matching clean entry logged" "$(lines)" "1"
TREE=$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["tree"])' "$(LOGF)")
chk "entry carries the logger's tree, not the caller's" "$TREE" "$S2"

printf 'fix\n' >> "$REPO/a.txt"
log '{"skill":"review","status":"clean","start_tree":"'"$S2"'","completed":true,"converged":true}' >/dev/null 2>&1; RC=$?
chk "clean refused after the tree moved" "$RC" "1"
chk "refused entry not written" "$(lines)" "1"

mkdir -p "$TMP/notrepo"
(cd "$TMP/notrepo" && "$BIN/vibe-review-log" '{"skill":"review","status":"clean","start_tree":"'"$S2"'"}' >/dev/null 2>&1); RC=$?
chk "clean refused when the tree cannot be snapshotted now" "$RC" "1"
log '{"skill":"review","status":"clean","completed":false}' >/dev/null 2>&1; RC=$?
chk "clean refused when completed=false" "$RC" "1"
log '{"skill":"review","status":"clean","converged":false}' >/dev/null 2>&1; RC=$?
chk "clean refused when converged=false" "$RC" "1"
chk "no refused entry written" "$(lines)" "1"

log '{"skill":"review","status":"incomplete","completed":false,"start_tree":"START_TREE"}' >/dev/null; RC=$?
chk "incomplete status logs" "$RC" "0"
HAS=$(python3 -I -c 'import json,sys; print("start_tree" in json.loads(open(sys.argv[1]).readlines()[-1]))' "$(LOGF)")
chk "START_TREE placeholder dropped" "$HAS" "False"
log '{"skill":"review","status":"issues_found","start_tree":"'"$S2"'","converged":false}' >/dev/null; RC=$?
chk "issues_found logs despite a moved tree" "$RC" "0"
log '{"skill":"codex","status":"clean"}' >/dev/null; RC=$?
chk "callers without the new fields are unaffected" "$RC" "0"

echo "specialist stats"
LF=$(LOGF)
for _ in 1 2 3; do
  printf '%s\n' '{"skill":"review","specialists":{"testing":{"dispatched":true,"completed":false,"findings":0}}}' >> "$LF"
done
printf '%s\n' '{"skill":"review","specialists":{"testing":{"dispatched":true,"completed":true,"findings":0}}}' >> "$LF"
STATS=$(cd "$REPO" && "$BIN/vibe-specialist-stats" --min-dispatches 2)
printf '%s\n' "$STATS" | grep -Eq '^testing +dispatched=1 findings=0 +active$' \
  && ok "failed specialist runs do not count toward gating" || no "failed runs counted: $STATS"

echo "review skill contracts"
has() { if grep -qF -- "$2" "$SK"; then ok "$1"; else no "$1 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$SK"; then no "$1 (still present: $2)"; else ok "$1"; fi; }
STEP1=$(awk '/^## Step 1: Check branch/{on=1;next} on&&/^## /{exit} on' "$SK")
if printf '%s' "$STEP1" | grep -qF 'git fetch origin <base> --quiet &&'; then
  no "Step 1 still chains the fetch into the diff"
else ok "Step 1 fetch is separate from the diff"; fi
printf '%s' "$STEP1" | grep -qF 'BASE_REFRESH: stale' && ok "Step 1 reports a stale base" || no "Step 1 has no stale-base report"
printf '%s' "$STEP1" | grep -qF 'ls-files --others --exclude-standard' && ok "Step 1 counts untracked files" || no "Step 1 ignores untracked files"
N=$(grep -cF 'ls-files --others --exclude-standard' "$SK")
[ "$N" -ge 6 ] && ok "untracked files reach Step 3 and every reviewer ($N)" || no "untracked instruction appears only $N times"
hasnt "specialist failure no longer 'partial results'" "partial results are better than no results"
hasnt "red team failure no longer silent" "skip silently and continue"
hasnt "all-failed adversarial still persisted" "If all passes failed, do NOT persist"
has "adversarial record carries completed" '"completed":COMPLETED,"start_tree":"START_TREE","commit"'
has "bounded re-review step" "### Step 5e: Re-review the fixes (bounded)"
has "review record carries the start snapshot" '"start_tree":"START_TREE"'
has "review record carries convergence" '"converged":CONVERGED'
has "Step 3 captures the snapshot" "vibe-review-log --snapshot"
# Plan discovery lives in a shared snippet, so read the rendered skill.
RSK="$TMP/review-rendered.md"
if "$BIN/vibe-render-skill" "$SK" "$RSK" >/dev/null 2>&1; then
  grep -qF 'PLAN_BINDING:' "$RSK" && ok "plan discovery reads the PR body binding" || no "plan discovery reads the PR body binding"
  grep -qF -- '-mmin -1440' "$RSK" && no "plan discovery still takes the newest plan" || ok "plan discovery never takes the newest plan"
else
  no "review skill does not render"
fi
has "codex structured gate says untracked files are outside it" "Untracked files are outside this gate."

echo "ship dashboard honours the tree binding"
SHIP="$SRC/skills/ship/SKILL.md"
DASH=$(awk '/^## Review Readiness Dashboard/{on=1;next} on&&/^## Step 2:/{exit} on' "$SHIP")
printf '%s' "$DASH" | grep -qF 'vibe-review-log --snapshot' && ok "ship snapshots the tree it ships" || no "ship dashboard takes no snapshot"
printf '%s' "$DASH" | grep -qF 'tree changed since review' && ok "ship refuses a review of a different tree" || no "ship clears a review of a different tree"
printf '%s' "$DASH" | grep -qF '`incomplete`' && ok "ship treats incomplete as not clean" || no "ship ignores the incomplete status"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
