#!/usr/bin/env bash
# test-ship-release-gates.sh — /ship's version, push, distribution and release
# gates behave on real fixture repos, and the step text keeps its contracts.
#
# The bash blocks are pulled out of the rendered skill and executed, so a change
# to the block itself is what gets tested:
#   - Step 12 classifies a repo with no VERSION file as NO_VERSION and never
#     writes one; a malformed or branch-deleted VERSION stops with exit 2.
#   - Step 17 asks the remote with ls-remote; a failed lookup is BLOCKED, never
#     ALREADY_PUSHED off a stale origin/<branch> ref.
#   - Step 2 raises the pipeline question only for ADDED artifacts.
#   - Step 19 reads a merged PR as PR_MERGED (never NO_PR), so a re-run opens
#     no second PR and goes to the release step; a branch with commits past its
#     merged PR's head reads as NO_PR in Step 19 and not MERGED in Step 1.
# Then static checks: no tag or release before merge, no WIP checkpoint
# machinery, plan binding instead of newest-file fallback (in /ship and /review,
# through the same block), the test value bar.
#
# Usage: test-ship-release-gates.sh [SKILL.md]   (default: skills/ship/SKILL.md;
#        REVIEW_SKILL overrides skills/review/SKILL.md)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/skills/ship/SKILL.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SKILL="$TMP/SKILL.md"
if ! "$ROOT/bin/vibe-render-skill" "$SRC" "$SKILL" >/dev/null 2>&1; then
  echo "cannot render $SRC" >&2; exit 1
fi

# block MARKER -> the first ```bash fence after the first line containing MARKER
block() {
  python3 -I - "$SKILL" "$1" <<'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
marker = sys.argv[2]
start = next((i for i, l in enumerate(text) if marker in l), None)
if start is None:
    sys.exit(1)
out, on = [], False
for line in text[start:]:
    if not on and line.strip() == "```bash":
        on = True
        continue
    if on and line.strip() == "```":
        break
    if on:
        out.append(line)
if not out:
    sys.exit(1)
print("\n".join(out))
PY
}

section() { awk -v a="$1" -v b="$2" 'index($0,a)==1 {on=1} on && index($0,b)==1 && index($0,a)!=1 {exit} on' "$SKILL"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# fixture NAME BASE_VERSION -> repo at $TMP/NAME on branch feature, origin has main
fixture() {
  local d="$TMP/$1"
  git init -q --bare "$d.git"
  git init -q -b main "$d"
  ( cd "$d" || exit 1
    echo app > app.txt
    [ -n "$2" ] && printf '%s\n' "$2" > VERSION
    git add -A && git commit -q -m init
    git remote add origin "$d.git"
    git push -q origin main
    git checkout -q -b feature )
  printf '%s' "$d"
}

echo "Step 12: version state"
VBLOCK="$TMP/version.sh"
if block '**Idempotency check:** Before bumping' > "$VBLOCK"; then
  sed -i.bak 's/<base>/main/g' "$VBLOCK"
  ok "version block extracted"
else
  no "version block not found"; : > "$VBLOCK"
fi
runv() { ( cd "$1" && bash "$VBLOCK" ) 2>&1; }

d=$(fixture nover "")
out=$(runv "$d"); rc=$?
case "$out" in *"STATE: NO_VERSION"*) ok "no VERSION anywhere -> NO_VERSION" ;; *) no "versionless repo not NO_VERSION: $out" ;; esac
[ "$rc" = 0 ] && ok "NO_VERSION exits 0" || no "NO_VERSION exit $rc"
[ ! -e "$d/VERSION" ] && ok "NO_VERSION never creates VERSION" || no "VERSION was created in a versionless repo"
case "$out" in *0.0.0*) no "versionless repo fabricated 0.0.0" ;; *) ok "no 0.0.0 fabricated" ;; esac

d=$(fixture fresh "1.2.3")
out=$(runv "$d")
case "$out" in *"STATE: FRESH"*) ok "VERSION equal to base -> FRESH" ;; *) no "unchanged VERSION not FRESH: $out" ;; esac

d=$(fixture bumped "1.2.3"); echo 1.2.4 > "$d/VERSION"
out=$(runv "$d")
case "$out" in *"STATE: ALREADY_BUMPED"*) ok "VERSION ahead of base -> ALREADY_BUMPED" ;; *) no "bumped VERSION not ALREADY_BUMPED: $out" ;; esac

d=$(fixture added ""); echo 0.1.0 > "$d/VERSION"
out=$(runv "$d")
case "$out" in *"STATE: ALREADY_BUMPED"*) ok "VERSION added on branch -> kept as ALREADY_BUMPED" ;; *) no "branch-added VERSION misclassified: $out" ;; esac

d=$(fixture bad "1.2.3"); echo 'one.two' > "$d/VERSION"
out=$(runv "$d"); rc=$?
[ "$rc" = 2 ] && ok "malformed VERSION stops with exit 2" || no "malformed VERSION exit $rc: $out"
case "$out" in *"STATE:"*) no "malformed VERSION still classified: $out" ;; *) ok "malformed VERSION is not classified" ;; esac

d=$(fixture empty "1.2.3"); : > "$d/VERSION"
out=$(runv "$d"); rc=$?
[ "$rc" = 2 ] && ok "empty VERSION stops with exit 2" || no "empty VERSION exit $rc: $out"

d=$(fixture deleted "1.2.3"); rm -f "$d/VERSION"
out=$(runv "$d"); rc=$?
[ "$rc" = 2 ] && ok "VERSION deleted on branch stops with exit 2" || no "deleted VERSION exit $rc: $out"

echo "Step 17: remote check"
PBLOCK="$TMP/push.sh"
if block '**Idempotency check:** Ask the remote directly' > "$PBLOCK"; then
  sed -i.bak 's/<branch-name>/feature/g' "$PBLOCK"
  ok "push check block extracted"
else
  no "push check block not found"; : > "$PBLOCK"
fi
runp() { ( cd "$1" && bash "$PBLOCK" ) 2>&1; }

d=$(fixture push "")
out=$(runp "$d")
case "$out" in *PUSH_NEEDED*) ok "branch absent on remote -> PUSH_NEEDED" ;; *) no "absent branch: $out" ;; esac
( cd "$d" && git push -q origin feature )
out=$(runp "$d")
case "$out" in *ALREADY_PUSHED*) ok "remote at HEAD -> ALREADY_PUSHED" ;; *) no "pushed branch: $out" ;; esac
( cd "$d" && git commit -q --allow-empty -m more )
out=$(runp "$d")
case "$out" in *PUSH_NEEDED*) ok "local ahead -> PUSH_NEEDED" ;; *) no "local ahead: $out" ;; esac
# A stale origin/feature that equals HEAD, with the remote unreachable: a check
# that trusts the local ref reports ALREADY_PUSHED for a push that never happened.
( cd "$d" && git update-ref refs/remotes/origin/feature HEAD && git remote set-url origin "$TMP/gone.git" )
out=$(runp "$d")
case "$out" in
  *REMOTE_LOOKUP_FAILED*) ok "unreachable remote -> REMOTE_LOOKUP_FAILED" ;;
  *) no "unreachable remote not reported as a failed lookup: $out" ;;
esac
case "$out" in *ALREADY_PUSHED*) no "stale local ref reported ALREADY_PUSHED" ;; *) ok "stale local ref is not trusted" ;; esac

echo "Step 2: distribution check"
DBLOCK="$TMP/dist.sh"
if block 'Check if the diff **adds** a new' > "$DBLOCK"; then
  sed -i.bak 's/<base>/main/g' "$DBLOCK"
  ok "distribution block extracted"
else
  no "distribution block not found"; : > "$DBLOCK"
fi
d=$(fixture dist "")
( cd "$d" && mkdir -p bin && echo 'echo hi' > bin/tool && git add -A && git commit -q -m tool && git push -q origin feature:main \
  && git fetch -q origin && git checkout -q -B feature origin/main && echo 'echo bye' > bin/tool && git commit -q -am edit )
out=$( cd "$d" && bash "$DBLOCK" 2>&1 )
[ -z "$out" ] && ok "editing an existing bin/ file is not a new artifact" || no "edit under bin/ flagged: $out"
( cd "$d" && echo 'echo new' > bin/newtool && git add bin/newtool && git commit -q -m add )
out=$( cd "$d" && bash "$DBLOCK" 2>&1 )
case "$out" in *bin/newtool*) ok "an added bin/ file is a new artifact" ;; *) no "added bin/ file missed: $out" ;; esac

echo "release and tags"
S15=$(section '## Step 15.2:' '## Step 16:')
S17=$(section '## Step 17:' '## Step 19:')
S195=$(section '## Step 19.5:' '## Step 20:')
grep -Eq '^[[:space:]]*git tag -f|&& git tag -f|tag -fa' "$SKILL" && no "a tag is still force-created or moved" || ok "no tag -f anywhere"
grep -Eq '^[[:space:]]*git push --force' "$SKILL" && no "a tag is still force-pushed" || ok "no tag force-push"
printf '%s' "$S17" | grep -q -- '--follow-tags' && no "Step 17 still pushes tags" || ok "Step 17 pushes no tags"
printf '%s' "$S15" | grep -Eq 'git tag( |$)' && no "Step 15.2 still creates a tag" || ok "Step 15.2 creates no tag"
merged_at=$(printf '%s\n' "$S195" | grep -n 'state,mergeCommit' | head -1 | cut -d: -f1)
release_at=$(printf '%s\n' "$S195" | grep -n 'gh release create' | head -1 | cut -d: -f1)
if [ -n "$merged_at" ] && [ -n "$release_at" ] && [ "$merged_at" -lt "$release_at" ]; then
  ok "release is gated behind the merged check"
else
  no "Step 19.5 creates a release without first checking the PR is merged"
fi
printf '%s' "$S195" | grep -q 'Release deferred' && ok "unmerged PR defers the release" || no "no deferral path for an unmerged PR"
printf '%s' "$S195" | grep -q 'NO_VERSION' && ok "release skipped under NO_VERSION" || no "Step 19.5 ignores NO_VERSION"

echo "push failure protocol"
printf '%s' "$S17" | grep -q 'Push-failure protocol' && ok "push failure has a protocol" || no "no push-failure protocol"
printf '%s' "$S17" | grep -q 'non-fast-forward' && ok "non-fast-forward handled" || no "non-fast-forward not handled"
printf '%s' "$S17" | grep -Eq 'git fetch origin <branch-name> 2>/dev/null$' && no "Step 17 still trusts a silenced fetch" || ok "no silenced fetch before the comparison"

echo "documentation sync before push"
doc_at=$(grep -n '^## Step 14.5: Documentation sync' "$SKILL" | cut -d: -f1)
commit_at=$(grep -n '^## Step 15: Commit' "$SKILL" | cut -d: -f1)
gate_at=$(grep -n '^## Step 16: Verification Gate' "$SKILL" | cut -d: -f1)
push_at=$(grep -n '^## Step 17: Push' "$SKILL" | cut -d: -f1)
if [ -n "$doc_at" ] && [ -n "$commit_at" ] && [ "$doc_at" -lt "$commit_at" ] && [ "$commit_at" -lt "$gate_at" ] && [ "$gate_at" -lt "$push_at" ]; then
  ok "doc sync runs before commit, verification and push"
else
  no "doc sync is not ahead of Steps 15-17 (doc=$doc_at commit=$commit_at gate=$gate_at push=$push_at)"
fi
grep -q '^## Step 18: Documentation sync' "$SKILL" && no "a post-push doc sync step still exists" || ok "no doc sync after push"

echo "checkpoint commits"
grep -q 'CHECKPOINT_MODE' "$SKILL" && no "rendered ship still carries CHECKPOINT_MODE" || ok "no CHECKPOINT_MODE"
grep -q 'WIP Commit Squash' "$SKILL" && no "ship still squashes WIP commits" || ok "no WIP squash step"
grep -q 'checkpoint_push\|CHECKPOINT_PUSH' "$ROOT/lib/snippets/session-host.md" && no "session-host still echoes checkpoint flags" || ok "session-host has no checkpoint flags"
grep -q '^WIP:' "$ROOT/lib/snippets/state-protocols.md" && no "state-protocols still instructs WIP commits" || ok "state-protocols has no WIP commits"

echo "plan binding"
S8=$(section '## Step 8: Plan Completion Audit' '## Step 8.1:')
printf '%s' "$S8" | grep -q -- '-mmin' && no "plan discovery still falls back to the newest file" || ok "no newest-file fallback"
printf '%s' "$S8" | grep -q 'PLAN_BINDING' && ok "PR body Plan: binding read" || no "no Plan: binding"
printf '%s' "$S8" | grep -q 'Plan completion audit: not run' && ok "honest not-run line" || no "no not-run line"

echo "re-run on a merged PR"
mkdir -p "$TMP/stub"
cat > "$TMP/stub/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] || exit 1
shift 2; q=""
while [ $# -gt 0 ]; do case "$1" in -q) q="$2"; shift 2 ;; *) shift ;; esac; done
[ -f "$STUB_PR" ] || exit 1
if [ -n "$q" ]; then jq -r "$q" "$STUB_PR"; else cat "$STUB_PR"; fi
SH
chmod +x "$TMP/stub/gh"
IBLOCK="$TMP/idem.sh"
if block '**Idempotency check:** Check if a PR/MR already exists' > "$IBLOCK"; then
  ok "Step 19 idempotency block extracted"
else
  no "Step 19 idempotency block not found"; : > "$IBLOCK"
fi
PBLOCK="$TMP/preflight.sh"
if block "Then check whether this branch's PR/MR already merged" > "$PBLOCK"; then
  ok "Step 1 merged-PR block extracted"
else
  no "Step 1 merged-PR block not found"; : > "$PBLOCK"
fi
# A branch whose PR merged at OLD, with one more commit (HEAD) made after the merge.
REPO="$TMP/reuse"
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m merged
OLD_HEAD=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "new work"
NEW_HEAD=$(git -C "$REPO" rev-parse HEAD)
runb() { printf '{"state":"%s","number":7,"url":"https://x/pull/7","headRefOid":"%s"}\n' "$2" "${3:-$NEW_HEAD}" > "$TMP/pr.json"
         ( cd "$REPO" && PATH="$TMP/stub:$PATH" STUB_PR="$TMP/pr.json" bash "$1" 2>&1 ); }
runi() { runb "$IBLOCK" "$@"; }
if command -v jq >/dev/null 2>&1; then
  out=$(runi MERGED)
  case "$out" in *PR_MERGED*) ok "merged PR is detected as merged" ;; *) no "merged PR reads as: $out" ;; esac
  case "$out" in *NO_PR*) no "merged PR falls into NO_PR (a new PR would be created)" ;; *) ok "merged PR is not NO_PR" ;; esac
  out=$(runi MERGED "$OLD_HEAD")
  case "$out" in *PR_MERGED*) no "branch reused after its merge reads as PR_MERGED (new commits never shipped): $out" ;;
    *NO_PR*) ok "branch reused after its merge gets a new PR" ;; *) no "reused branch reads as: $out" ;; esac
  out=$(runb "$PBLOCK" MERGED)
  case "$out" in MERGED*) ok "pre-flight: PR merged at HEAD reads MERGED" ;; *) no "pre-flight: PR merged at HEAD reads as: $out" ;; esac
  out=$(runb "$PBLOCK" MERGED "$OLD_HEAD")
  case "$out" in MERGED*) no "pre-flight: commits after the merge read MERGED (they would skip the whole ship): $out" ;;
    *) ok "pre-flight: commits after the merge are shipped, not released" ;; esac
  out=$(runb "$PBLOCK" OPEN)
  case "$out" in MERGED*) no "pre-flight: open PR reads MERGED" ;; *) ok "pre-flight: open PR is not MERGED" ;; esac
  out=$(runi OPEN)
  case "$out" in "PR #7"*) ok "open PR still updated in place" ;; *) no "open PR reads as: $out" ;; esac
  out=$(runi CLOSED)
  case "$out" in *NO_PR*) ok "closed-unmerged PR gets a fresh PR" ;; *) no "closed PR reads as: $out" ;; esac
else
  no "jq is required for the Step 19 idempotency check"
fi
S19=$(section '## Step 19: Create PR/MR' '## Step 19.5:')
printf '%s' "$S19" | grep -q 'PR_MERGED.*go straight to Step 19.5\|go straight to Step 19.5' \
  && ok "merged PR goes to the release step" || no "Step 19 does not route a merged PR to Step 19.5"
S1=$(section '## Step 1: Pre-flight' '## Step 2:')
printf '%s' "$S1" | grep -q 'MERGED' && printf '%s' "$S1" | grep -q 'Step 19.5' \
  && ok "pre-flight short-circuits a merged PR to the release" || no "pre-flight re-ships a merged PR (bump + new PR)"
printf '%s' "$S195" | grep -q 'gh release create "$TAG_NAME" --verify-tag' \
  && ok "Step 19.5 renders the shared release block" || no "Step 19.5 does not use the shared release block"
printf '%s' "$S195" | grep -q '/land-and-deploy does not tag or release' \
  && no "Step 19.5 still says /land-and-deploy never releases" || ok "deferral points at /land-and-deploy"

echo "review plan binding"
REVIEW_SRC="${REVIEW_SKILL:-$ROOT/skills/review/SKILL.md}"
RSKILL="$TMP/review.md"
if "$ROOT/bin/vibe-render-skill" "$REVIEW_SRC" "$RSKILL" >/dev/null 2>&1; then
  RPD=$(awk 'index($0,"### Plan File Discovery")==1 {on=1} on && index($0,"### Actionable Item Extraction")==1 {exit} on' "$RSKILL")
  printf '%s' "$RPD" | grep -Eq -- '-mmin|ls -t' && no "review still falls back to the newest plan file" || ok "review has no newest-modified fallback"
  printf '%s' "$RPD" | grep -q 'PLAN=\$(' && no "review still picks a content-search hit silently" || ok "review never picks a candidate silently"
  printf '%s' "$RPD" | grep -q 'PLAN_BINDING' && ok "review reads the PR body Plan: binding" || no "review has no Plan: binding"
  printf '%s' "$RPD" | grep -q 'PLAN_CANDIDATE' && ok "review lists candidates for the user" || no "review lists no candidates"
  printf '%s' "$RPD" | grep -q 'Plan completion audit: not run' && ok "review prints the honest not-run line" || no "review has no not-run line"
  block '**Content-based search (candidates only)' > "$TMP/ship-plan.sh" 2>/dev/null
  SKILL="$RSKILL" block '**Content-based search (candidates only)' > "$TMP/review-plan.sh" 2>/dev/null
  [ -s "$TMP/ship-plan.sh" ] && cmp -s "$TMP/ship-plan.sh" "$TMP/review-plan.sh" \
    && ok "ship and review bind the plan with the same block" || no "ship and review plan discovery differ"
else
  no "review skill does not render"
fi

echo "test value bar"
S7=$(section '## Step 7: Test Coverage Audit' '## Step 8:')
printf '%s' "$S7" | grep -q 'Value card' && ok "value bar snippet rendered into Step 7" || no "value bar not included in Step 7"
printf '%s' "$S7" | grep -q '20 tests generated max' && no "Step 7 still caps at 20 generated tests" || ok "20-test cap gone"
printf '%s' "$S7" | grep -q '5 tests written per pass' && ok "5-per-pass cap" || no "no 5-per-pass cap"
printf '%s' "$S7" | grep -q 'Extend first' && ok "extend-first rule" || no "no extend-first rule"
printf '%s' "$S7" | grep -q 'fail on its own' && ok "regression proof required" || no "no regression proof"
printf '%s' "$S7" | grep -Eq 'commit as `test: coverage|Passes → commit' && no "subagent still told to commit" || ok "subagent never told to commit"

echo "eval selection"
S6=$(section '## Step 6: Eval Suites' '## Step 7:')
printf '%s' "$S6" | grep -q 'Example only' && ok "app layout is an example, not the selector" || no "Step 6 still hard-codes one app layout"
printf '%s' "$S6" | grep -q 'none declared' && ok "prompt changes without evals are a named gap" || no "no named gap for prompt changes without evals"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
