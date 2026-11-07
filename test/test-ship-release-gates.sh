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

# The skills' blocks resolve helpers as ${VIBESTACK_HOME:-$HOME/.vibestack}/bin.
VH="$TMP/vh"; mkdir -p "$VH"; ln -s "$ROOT/bin" "$VH/bin"

echo "Step 5: a suite that ran nothing is not a pass"
LBLOCK="$TMP/lanes.sh"
block '## Step 5: Run tests' > "$LBLOCK" && ok "lane block extracted" || { no "lane block not found"; : > "$LBLOCK"; }
mkdir -p "$TMP/logs"
printf 'No tests found, exiting with code 0\n' > "$TMP/logs/jest0"
printf '============ no tests ran in 0.01s ============\n' > "$TMP/logs/pytest0"
printf 'Finished in 0.001 seconds\n0 examples, 0 failures\n' > "$TMP/logs/rspec0"
printf '?   \texample.com/x\t[no test files]\n' > "$TMP/logs/go0"
printf ' 0 pass\n 0 fail\nRan 0 tests across 1 files. [5ms]\n' > "$TMP/logs/bun0"
printf ' 12 pass\n 0 fail\n 30 expect() calls\nRan 12 tests across 3 files. [40ms]\n' > "$TMP/logs/bun12"
printf 'Test Suites: 1 passed, 1 total\nTests:       3 passed, 3 total\nSnapshots:   0 total\n' > "$TMP/logs/jest3"
printf '=========== 4 passed, 1 failed in 0.20s ===========\n' > "$TMP/logs/pytest5"
printf '7 examples, 0 failures\n' > "$TMP/logs/rspec7"
printf 'ok  \texample.com/x\t0.01s\n?   \texample.com/y\t[no test files]\n' > "$TMP/logs/gomixed"
printf 'all good\n' > "$TMP/logs/custom"
printf 'TAP version 13\n1..0\n# tests 0\n# pass 0\n# fail 0\n' > "$TMP/logs/nodetap0"
printf '\342\204\271 tests 0\n\342\204\271 pass 0\n' > "$TMP/logs/nodespec0"
printf '# tests 4\n# pass 4\n' > "$TMP/logs/nodetap4"
printf 'running 0 tests\n\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n' > "$TMP/logs/cargo0"
printf 'test result: ok. 2 passed; 0 failed; 0 ignored\ntest result: FAILED. 1 passed; 1 failed; 0 ignored\n' > "$TMP/logs/cargo4"
# ran FIXTURE -> the tests_ran value the lane block reports for a lane whose
# output is that fixture (the lane itself exits 0 every time).
ran() {
  python3 -I - "$LBLOCK" "$TMP/lanes.$1.sh" "$TMP/logs/$1" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("'<test command for lane 1>'", "'cat %s'" % sys.argv[3]).replace("'<test command for lane 2>'", "'true'")
t = t.replace("<lane1>", "a").replace("<lane2>", "b")
open(sys.argv[2], "w").write(t)
PY
  ( cd "$TMP" && VIBESTACK_HOME="$VH" bash "$TMP/lanes.$1.sh" 2>&1 ) | sed -n 's/^LANE: a exit=0 tests_ran=\([^ ]*\) .*/\1/p'
}
for f in jest0 pytest0 rspec0 go0 bun0 nodetap0 nodespec0 cargo0; do
  got=$(ran "$f")
  [ "$got" = 0 ] && ok "$f: zero-test run reports tests_ran=0" || no "$f: zero-test run reports tests_ran='$got'"
done
for pair in bun12:12 jest3:3 pytest5:5 rspec7:7 nodetap4:4 cargo4:4; do
  got=$(ran "${pair%%:*}")
  [ "$got" = "${pair#*:}" ] && ok "${pair%%:*}: counted ${pair#*:} tests" || no "${pair%%:*}: tests_ran='$got', want ${pair#*:}"
done
for f in gomixed custom; do
  got=$(ran "$f")
  [ "$got" = unknown ] && ok "$f: no runner count -> tests_ran=unknown" || no "$f: tests_ran='$got', want unknown"
done
S5=$(section '## Step 5: Run tests' '## Test Failure Ownership Triage')
S16=$(section '## Step 16: Verification Gate' '## Step 17:')
printf '%s' "$S5" | grep -q 'tests_ran=0' && printf '%s' "$S5" | grep -q 'Step T2' \
  && ok "tests_ran=0 goes to in-branch triage" || no "Step 5 does not route tests_ran=0 to Step T2"
printf '%s' "$S5" | grep -q 'count unavailable' && ok "unknown count passes as 'count unavailable'" || no "no 'count unavailable' rule"
printf '%s' "$S16" | grep -q 'tests_ran' && ok "Step 16 refuses a zero-test lane as FRESH" || no "Step 16 ignores tests_ran"
S19T=$(section '## Test plan' '<If SHIP_ATTRIBUTION')
printf '%s' "$S19T" | grep -q 'tests_ran' && ok "PR Test plan prints per-lane counts" || no "PR Test plan has no per-lane count"

echo "Steps 5-6: logs in a private directory"
grep -q '/tmp/vibestack-ship-$(git branch' "$SKILL" && no "lane/eval logs still go to a predictable /tmp path" || ok "no predictable /tmp log path"
printf '%s' "$S5" | grep -q 'mktemp -d' && ok "Step 5 logs to a private mktemp -d" || no "Step 5 has no private log dir"
printf '%s' "$S6" | grep -q 'vibe-detach" start' && printf '%s' "$S6" | grep -q 'vibe-detach" status' \
  && ok "long eval suites run detached and are polled" || no "Step 6 has no detached eval path"
printf '%s' "$S6" | grep -qi 'silence is not success' && ok "a silent job is not a pass" || no "no 'silence is not success' rule"

echo "Step 12: version files move through vibe-version-bump"
grep -q 'JSON.stringify' "$SKILL" && no "ship still rewrites package.json with JSON.stringify" || ok "no hand-rolled package.json write"
WBLOCK="$TMP/write.sh"
block '4. **Validate**' > "$WBLOCK" && ok "version write block extracted" || { no "version write block not found"; : > "$WBLOCK"; }
sed -i.bak "s/<NEW_VERSION>/1.2.4/g" "$WBLOCK"
npm_fixture() { # npm_fixture NAME LOCK_BODY
  local d; d=$(fixture "$1" "1.2.3")
  printf '{\n  "name": "x",\n  "version": "1.2.3"\n}\n' > "$d/package.json"
  printf '%s\n' "$2" > "$d/package-lock.json"
  printf '%s' "$d"
}
d=$(npm_fixture bumplock '{"name":"x","version":"1.2.3","lockfileVersion":3,"packages":{"":{"name":"x","version":"1.2.3"}}}')
out=$( cd "$d" && VIBESTACK_HOME="$VH" bash "$WBLOCK" 2>&1 ); rc=$?
[ "$rc" = 0 ] && ok "bump exits 0" || no "bump exit $rc: $out"
[ "$(cat "$d/VERSION")" = 1.2.4 ] && ok "VERSION written" || no "VERSION not written"
grep -q '"version": "1.2.4"' "$d/package.json" && ok "package.json written" || no "package.json not written"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); sys.exit(0 if l["version"]=="1.2.4" and l["packages"][""]["version"]=="1.2.4" else 1)' "$d/package-lock.json" \
  && ok "package-lock.json moves with the manifest" || no "package-lock.json left at the old version"
d=$(npm_fixture badlock 'not json')
out=$( cd "$d" && VIBESTACK_HOME="$VH" bash "$WBLOCK" 2>&1 ); rc=$?
[ "$rc" != 0 ] && ok "an unwritable lockfile stops the bump" || no "malformed lockfile still exited 0"
[ "$(cat "$d/VERSION")" = 1.2.3 ] && ok "and nothing was written" || no "VERSION moved although the bump failed"
S12=$(section '## Step 12: Version bump' '## Step 13:')
printf '%s' "$S12" | grep -q 'DRIFT_STALE_PKG repair' && printf '%s' "$S12" | grep -q 'vibe-version-bump" "$REPAIR_VERSION"' \
  && ok "drift repair goes through vibe-version-bump" || no "drift repair does not use vibe-version-bump"

echo "Step 12: own PR excluded from the queue"
QBLOCK="$TMP/queue.sh"
block '3. **Queue-aware version pick' > "$QBLOCK" && ok "queue block extracted" || { no "queue block not found"; : > "$QBLOCK"; }
sed -i.bak -e "s/<BUMP_LEVEL>/patch/g" -e "s/<BASE_VERSION>/1.2.3/g" -e "s/<base>/main/g" "$QBLOCK"
QH="$TMP/qh"; mkdir -p "$QH/bin"
cat > "$QH/bin/vibe-next-version" <<'SH'
#!/usr/bin/env bash
printf '%s|' "$@" > "$ARGS_OUT"
echo '{"version":"1.2.4","claimed":[],"offline":false}'
SH
chmod +x "$QH/bin/vibe-next-version"
printf '{"number":7}\n' > "$TMP/own-pr.json"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ( cd "$TMP" && PATH="$TMP/stub:$PATH" STUB_PR="$TMP/own-pr.json" VIBESTACK_HOME="$QH" ARGS_OUT="$TMP/args.$sh" "$sh" "$QBLOCK" >/dev/null 2>&1 )
  grep -q '|--exclude-pr|7|' "$TMP/args.$sh" 2>/dev/null && ok "$sh: own PR passed as --exclude-pr 7 (two arguments)" || no "$sh: queue call args: $(cat "$TMP/args.$sh" 2>/dev/null)"
  ( cd "$TMP" && PATH="$TMP/stub:$PATH" STUB_PR="$TMP/none.json" VIBESTACK_HOME="$QH" ARGS_OUT="$TMP/args0.$sh" "$sh" "$QBLOCK" >/dev/null 2>&1 )
  grep -q 'exclude-pr' "$TMP/args0.$sh" 2>/dev/null && no "$sh: --exclude-pr sent with no PR" || ok "$sh: no PR -> no --exclude-pr"
done
printf '%s' "$S12" | grep -q "ALREADY_BUMPED.*step 3's block" && ok "ALREADY_BUMPED drift check reuses the excluding block" || no "ALREADY_BUMPED drift check does not exclude its own PR"

echo "Step 13: CHANGELOG follows the file"
S13=$(section '## Step 13: CHANGELOG' '## Step 14:')
printf '%s' "$S13" | grep -qF '## [X.Y.Z.W]' && no "Step 13 still hard-codes a header format" || ok "no hard-coded header format"
printf '%s' "$S13" | grep -q 'first release entry' && ok "entry goes before the first release entry" || no "no placement rule"
printf '%s' "$S13" | grep -q 'CHANGELOG: skipped' && ok "missing CHANGELOG is skipped" || no "no CHANGELOG: skipped path"
printf '%s' "$S13" | grep -qi 'never create' && ok "never creates a CHANGELOG" || no "no never-create rule"
printf '%s' "$S13" | grep -qi 'no bullet' && ok "merges and bumps need no bullet" || no "no bookkeeping-commit rule"

echo "Step T: pre-existing is proven at base, not guessed"
ST=$(section '## Test Failure Ownership Triage' '## Step 6:')
printf '%s' "$ST" | grep -q 'heuristic' && no "triage still classifies by heuristic" || ok "no heuristic classification"
BBLOCK="$TMP/base.sh"
block 'Prove it at base' > "$BBLOCK" && ok "base proof block extracted" || { no "base proof block not found"; : > "$BBLOCK"; }
sed -i.bak -e "s/<base>/main/g" -e "s|<failing test command>|sh t.sh|g" "$BBLOCK"
base_fixture() { # base_fixture NAME BASE_EXIT
  local d; d=$(fixture "$1" "")
  ( cd "$d" && git checkout -q main && printf 'exit %s\n' "$2" > t.sh && git add t.sh && git commit -q -m t \
    && git push -q origin main && git checkout -q feature && git merge -q main && printf 'exit 1\n' > t.sh )
  printf '%s' "$d"
}
d=$(base_fixture redbase 1)
out=$( cd "$d" && bash "$BBLOCK" 2>&1 )
case "$out" in *"BASE_EXIT: 1"*) ok "red at base -> BASE_EXIT: 1" ;; *) no "red base: $out" ;; esac
[ "$(git -C "$d" worktree list | wc -l | tr -d ' ')" = 1 ] && ok "the base worktree is removed" || no "base worktree left behind"
d=$(base_fixture greenbase 0)
out=$( cd "$d" && bash "$BBLOCK" 2>&1 )
case "$out" in *"BASE_EXIT: 0"*) ok "green at base -> BASE_EXIT: 0" ;; *) no "green base: $out" ;; esac
d=$(base_fixture nobase 1); git -C "$d" update-ref -d refs/remotes/origin/main
out=$( cd "$d" && bash "$BBLOCK" 2>&1 )
case "$out" in *"BASE_EXIT: unavailable"*) ok "no base ref -> unavailable" ;; *) no "missing base: $out" ;; esac
printf '%s' "$ST" | grep -qi 'green at base' && printf '%s' "$ST" | grep -q 'in-branch' \
  && ok "green at base is in-branch" || no "no green-at-base rule"
printf '%s' "$ST" | grep -qi 'unavailable.*in-branch' && ok "unavailable defaults to in-branch" || no "no unavailable rule"
printf '%s' "$ST" | grep -qi 'waiver' && printf '%s' "$ST" | grep -q 'never FRESH' \
  && ok "a waiver never reads as FRESH" || no "no waiver rule"

echo "Step 4: bootstrap never clobbers the tree"
S4=$(section '## Step 4: Test Framework Bootstrap' '## Step 5:')
printf '%s' "$S4" | grep -q 'git checkout -- package.json' && no "bootstrap still reverts with git checkout -- package.json" || ok "no whole-file checkout revert"
printf '%s' "$S4" | grep -q 'delete silently' && no "B4.5 still deletes failing tests silently" || ok "no silent test deletion"
printf '%s' "$S4" | grep -q 'git status --porcelain' && printf '%s' "$S4" | grep -qi 'before install' \
  && ok "tree snapshotted before installing" || no "no pre-install snapshot"
printf '%s' "$S4" | grep -q 'git add -- ' && printf '%s' "$S4" | grep -q 'git diff --cached --name-only' \
  && ok "B8 stages by name and checks the index" || no "B8 does not stage by name"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
