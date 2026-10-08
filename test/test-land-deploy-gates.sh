#!/usr/bin/env bash
# test-land-deploy-gates.sh — /land-and-deploy merges only the approved commit,
# only over green CI, and reverts what actually landed.
#
# The skill's bash blocks are pulled out of the rendered SKILL.md and run in
# fixture repos (bare origin) against a stub `gh` that serves canned JSON and
# records every merge call. Each scenario runs under bash and, when present, zsh
# (the blocks execute in the user's shell):
#   - Step 1 binds REPO / PR_NUMBER / PR_HEAD, refuses a checkout that is not the
#     PR head or has tracked edits, and classifies the diff before the merge;
#   - the CI gate reads every check on the head commit: no checks, a red optional
#     check, a pending check, a failed API call or a moved head is never PASS;
#   - the merge block refuses (and never calls `gh pr merge`) unless CI is green on
#     PR_HEAD or the user approved "no CI" for that exact head, and always passes
#     the PR number, --repo and --match-head-commit;
#   - the merge method comes from the Deploy Configuration first; an unknown or
#     disallowed method, or unreadable repo settings with none configured, stops;
#   - the readback tells a queued PR (OPEN + queue entry) from one removed from
#     the queue (OPEN, nothing armed) instead of polling PR state;
#   - the revert handles merge commits (-m 1) and rebase merges (the whole range),
#     and refuses a dirty tree;
#   - the test command's exit status survives (no pipe into tail);
#   - static contract: no bun default, no "merge anyway" past blockers, PR body
#     through vibe-untrusted, every merge bound to the head, honest verdicts.
#
# Usage: test/test-land-deploy-gates.sh   (LAND_SKILL overrides the source)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${LAND_SKILL:-$ROOT/skills/land-and-deploy/SKILL.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

SKILL="$TMP/skill.md"
"$ROOT/bin/vibe-render-skill" "$SRC" "$SKILL" >/dev/null 2>&1 || { echo "render failed: $SRC" >&2; exit 1; }

# block MARKER -> the first ```bash fence after the first line containing MARKER
block() {
  python3 -I - "$SKILL" "$1" <<'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
start = next((i for i, l in enumerate(text) if sys.argv[2] in l), None)
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

# fill BLOCKFILE OUT NAME=VALUE... -> replace "<NAME>" placeholders and the block's
# own leading `NAME=default` assignments with the given values.
fill() {
  python3 -I - "$@" <<'PY'
import re, sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(src).read()
for p in pairs:
    k, v = p.split("=", 1)
    text = text.replace("<%s>" % k, v)
    text = re.sub(r"(?m)^%s=(\"[^\"]*\"|\S*)" % re.escape(k), lambda m: '%s="%s"' % (k, v), text)
open(dst, "w").write(text)
PY
}

block "3. Resolve the target once" > "$TMP/target.sh" || no "no Step 1 target block"
block 'The CI gate reads **every** check' > "$TMP/gate.sh" || no "no Step 2 CI gate block"
block '**Merge method.**' > "$TMP/method.sh" || no "no merge-method block"
block '**Readback — the only dispatcher.**' > "$TMP/readback.sh" || no "no readback block"
block '**The merge block.**' > "$TMP/merge.sh" || no "no merge block"
block '## Step 8: Revert' > "$TMP/revert.sh" || no "no revert block"
block '### 3.5b: Test results' > "$TMP/tests.sh" || no "no test-command block"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# Stub gh: canned JSON per endpoint from $FX, filtered like gh's -q/--jq. Every
# call is logged; `pr merge` is recorded in merges.log.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/calls.log"
q=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--jq) q="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
serve() {  # serve FILE: emit it through the filter, or fail like an API error
  [ -f "$FX/$1" ] || { echo "HTTP 502: stub has no $1" >&2; exit 1; }
  if [ -n "$q" ]; then jq -r "$q" "$FX/$1"; else cat "$FX/$1"; fi
}
case "${args[0]} ${args[1]:-}" in
  "repo view") serve repo-view.json ;;
  "pr view") serve pr.json ;;
  "pr merge") printf '%s\n' "${args[*]}" >> "$FX/merges.log"; exit "$(cat "$FX/merge.exit" 2>/dev/null || echo 0)" ;;
  "pr create") printf '%s\n' "${args[*]}" >> "$FX/creates.log" ;;
  api\ *)
    ep=""
    skip=0
    for a in "${args[@]:1}"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$a" in -f|-F|--field|--raw-field|-H) skip=1 ;; -*) ;; *) [ -z "$ep" ] && ep="$a" ;; esac
    done
    case "$ep" in
      graphql) serve graphql.json; exit "$(cat "$FX/graphql.exit" 2>/dev/null || echo 0)" ;;
      repos/*/commits/*/check-runs*) serve check-runs.json ;;
      repos/*/commits/*/status*) serve status.json ;;
      repos/*/*) serve repo.json ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin/gh" "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH"

SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

# repo NAME FILE -> work repo on `feature` (one commit touching FILE) with origin.
repo() {
  local d="$TMP/$1"
  git init -q --bare "$d.git"
  git init -q -b main "$d"
  ( cd "$d" || exit 1
    echo base > README.md; echo 'let a = 1' > app.js
    git add -A && git commit -q -m init
    git remote add origin "$d.git" && git push -q origin main
    git checkout -q -b feature
    echo change >> "$2"
    git add -A && git commit -q -m feature && git push -q origin feature )
  mkdir -p "$d.fx"
  echo '{"nameWithOwner":"acme/app"}' > "$d.fx/repo-view.json"
  printf '%s' "$d"
}
prjson() {  # prjson DIR STATE HEAD
  printf '{"number":12,"state":"%s","title":"Add thing","url":"https://x/pr/12","mergeable":"MERGEABLE","baseRefName":"main","headRefName":"feature","headRefOid":"%s","commits":[{"messageHeadline":"feature"}]}\n' "$2" "$3" > "$1.fx/pr.json"
}
checks() {  # checks DIR RUNS_JSON_ARRAY STATUSES_JSON_ARRAY
  printf '{"check_runs":%s}\n' "$2" > "$1.fx/check-runs.json"
  printf '{"statuses":%s}\n' "$3" > "$1.fx/status.json"
}
run() {  # run SHELL DIR SCRIPT
  ( cd "$2" && FX="$2.fx" "$1" "$3" ) 2>&1
}
merges() { [ -f "$1.fx/merges.log" ] && wc -l < "$1.fx/merges.log" | tr -d ' ' || echo 0; }

for SH in $SHELLS; do
  echo "[$SH] Step 1: target binding"
  d=$(repo "t1-$SH" app.js); H=$(git -C "$d" rev-parse HEAD)
  prjson "$d" OPEN "$H"
  fill "$TMP/target.sh" "$d.t.sh" PR_NUMBER=12
  out=$(run "$SH" "$d" "$d.t.sh"); rc=$?
  case "$out" in *"TARGET REPO=acme/app PR_NUMBER=12 PR_HEAD=$H BASE_BRANCH=main BASE_SHA="*) ok "[$SH] matching checkout prints the TARGET line" ;; *) no "[$SH] no TARGET line: $out" ;; esac
  [ "$rc" = 0 ] && ok "[$SH] matching checkout exits 0" || no "[$SH] matching checkout exit $rc"
  grep -q '^pr view 12 --repo acme/app' "$d.fx/calls.log" && ok "[$SH] #NNN is queried by number with --repo" || no "[$SH] PR not queried by number"
  case "$out" in *"SCOPE KNOWN=true DOCS_ONLY=false"*BACKEND=true*) ok "[$SH] code change: scope known, not docs-only" ;; *) no "[$SH] wrong code scope: $out" ;; esac

  prjson "$d" OPEN 0123456789abcdef0123456789abcdef01234567
  out=$(run "$SH" "$d" "$d.t.sh"); rc=$?
  case "$out" in *LOCAL_TARGET_MISMATCH*) ok "[$SH] head SHA mismatch aborts" ;; *) no "[$SH] head mismatch not detected: $out" ;; esac
  [ "$rc" != 0 ] && ok "[$SH] mismatch exits non-zero" || no "[$SH] mismatch exit 0"
  case "$out" in *"TARGET REPO"*) no "[$SH] mismatch still printed a TARGET" ;; *) ok "[$SH] mismatch prints no TARGET" ;; esac

  prjson "$d" OPEN "$H"; echo dirty >> "$d/app.js"
  out=$(run "$SH" "$d" "$d.t.sh"); rc=$?
  case "$out" in *LOCAL_TARGET_MISMATCH*) ok "[$SH] tracked edits abort" ;; *) no "[$SH] dirty tree accepted: $out" ;; esac
  git -C "$d" checkout -q -- app.js

  rm -f "$d.fx/pr.json"
  out=$(run "$SH" "$d" "$d.t.sh"); rc=$?
  case "$out" in *TARGET_UNKNOWN*) ok "[$SH] unreadable PR is TARGET_UNKNOWN" ;; *) no "[$SH] unreadable PR: $out" ;; esac

  d=$(repo "t1d-$SH" README.md); H=$(git -C "$d" rev-parse HEAD); prjson "$d" OPEN "$H"
  fill "$TMP/target.sh" "$d.t.sh" PR_NUMBER=12
  out=$(run "$SH" "$d" "$d.t.sh")
  case "$out" in *"SCOPE KNOWN=true DOCS_ONLY=true"*) ok "[$SH] docs-only change classified before merge" ;; *) no "[$SH] docs scope wrong: $out" ;; esac

  echo "[$SH] CI gate"
  d=$(repo "g-$SH" app.js); H=$(git -C "$d" rev-parse HEAD); prjson "$d" OPEN "$H"
  fill "$TMP/gate.sh" "$d.g.sh" REPO=acme/app PR_NUMBER=12 PR_HEAD="$H"
  gate() { checks "$d" "$1" "$2"; : > "$d.fx/calls.log"; run "$SH" "$d" "$d.g.sh" | head -1; }
  [ "$(gate '[]' '[]')" = "VERDICT NO_CHECKS $H" ] && ok "[$SH] no checks -> NO_CHECKS, not PASS" || no "[$SH] no checks: $(gate '[]' '[]')"
  [ "$(grep -c 'check-runs' "$d.fx/calls.log")" -ge 2 ] && ok "[$SH] NO_CHECKS is re-polled before it is believed" || no "[$SH] NO_CHECKS not re-polled"
  v=$(gate '[{"status":"completed","conclusion":"success","name":"build"},{"status":"completed","conclusion":"failure","name":"optional-lint"}]' '[]')
  [ "$v" = "VERDICT FAIL $H" ] && ok "[$SH] a red non-required check -> FAIL" || no "[$SH] red optional check: $v"
  v=$(gate '[{"status":"in_progress","conclusion":null,"name":"build"}]' '[]')
  [ "$v" = "VERDICT PENDING $H" ] && ok "[$SH] running check -> PENDING" || no "[$SH] pending: $v"
  v=$(gate '[{"status":"completed","conclusion":"success","name":"build"},{"status":"completed","conclusion":"skipped","name":"deploy"}]' '[{"state":"success","context":"ci/legacy"}]')
  [ "$v" = "VERDICT PASS $H" ] && ok "[$SH] all green -> PASS" || no "[$SH] green: $v"
  v=$(gate '[{"status":"completed","conclusion":"success","name":"build"}]' '[{"state":"failure","context":"ci/legacy"}]')
  [ "$v" = "VERDICT FAIL $H" ] && ok "[$SH] failing commit status -> FAIL" || no "[$SH] status failure: $v"
  checks "$d" '[]' '[]'; rm -f "$d.fx/status.json"
  v=$(run "$SH" "$d" "$d.g.sh" | head -1)
  [ "$v" = "VERDICT ERROR $H" ] && ok "[$SH] API failure -> ERROR, not no-checks" || no "[$SH] api failure: $v"
  checks "$d" '[{"status":"completed","conclusion":"success","name":"build"}]' '[]'
  prjson "$d" OPEN 0123456789abcdef0123456789abcdef01234567
  v=$(run "$SH" "$d" "$d.g.sh" | head -1)
  case "$v" in "VERDICT HEAD_CHANGED "*) ok "[$SH] moved head -> HEAD_CHANGED" ;; *) no "[$SH] moved head: $v" ;; esac

  echo "[$SH] merge block"
  d=$(repo "m-$SH" app.js); H=$(git -C "$d" rev-parse HEAD); prjson "$d" OPEN "$H"
  mb() { fill "$TMP/merge.sh" "$d.m.sh" REPO=acme/app PR_NUMBER=12 PR_HEAD="$H" "$@"; run "$SH" "$d" "$d.m.sh"; }
  checks "$d" '[]' '[]'
  out=$(mb MERGE_METHOD=squash); rc=$?
  case "$out" in *MERGE_REFUSED*) ok "[$SH] no CI, not approved -> refused" ;; *) no "[$SH] merged with no CI: $out" ;; esac
  [ "$(merges "$d")" = 0 ] && [ "$rc" != 0 ] && ok "[$SH] refused merge never calls gh pr merge" || no "[$SH] gh pr merge ran on refusal"
  out=$(mb MERGE_METHOD=squash NO_CI_APPROVED_HEAD=0123456789abcdef0123456789abcdef01234567)
  [ "$(merges "$d")" = 0 ] && ok "[$SH] no-CI approval for another head does not carry over" || no "[$SH] approval for another head merged"
  out=$(mb MERGE_METHOD=squash NO_CI_APPROVED_HEAD="$H")
  grep -qx -- "pr merge 12 --repo acme/app --squash --auto --delete-branch --match-head-commit $H" "$d.fx/merges.log" \
    && ok "[$SH] approved no-CI head merges with number, --repo and --match-head-commit" || no "[$SH] merge args: $(cat "$d.fx/merges.log" 2>/dev/null)"
  : > "$d.fx/merges.log"
  checks "$d" '[{"status":"completed","conclusion":"failure","name":"optional"}]' '[]'
  out=$(mb MERGE_METHOD=squash NO_CI_APPROVED_HEAD="$H")
  [ "$(merges "$d")" = 0 ] && ok "[$SH] red CI at merge time -> no merge" || no "[$SH] merged over red CI"
  checks "$d" '[{"status":"queued","conclusion":null,"name":"build"}]' '[]'
  out=$(mb MERGE_METHOD=squash)
  [ "$(merges "$d")" = 0 ] && ok "[$SH] pending CI at merge time -> no merge" || no "[$SH] merged over pending CI"
  checks "$d" '[{"status":"completed","conclusion":"success","name":"build"}]' '[]'
  out=$(mb MERGE_METHOD=fast-forward)
  case "$out" in *MERGE_REFUSED*) ok "[$SH] unknown method at merge time -> refused" ;; *) no "[$SH] unknown method: $out" ;; esac
  [ "$(merges "$d")" = 0 ] || no "[$SH] merged with an unknown method"
  prjson "$d" OPEN 0123456789abcdef0123456789abcdef01234567
  out=$(mb MERGE_METHOD=squash)
  [ "$(merges "$d")" = 0 ] && ok "[$SH] head moved after approval -> no merge" || no "[$SH] merged a moved head"
  prjson "$d" OPEN "$H"; git -C "$d" commit -q --allow-empty -m later
  out=$(mb MERGE_METHOD=squash)
  case "$out" in *LOCAL_TARGET_MISMATCH*) ok "[$SH] checkout moved after approval -> refused" ;; *) no "[$SH] moved checkout: $out" ;; esac
  git -C "$d" reset -q --hard "$H"
  out=$(mb MERGE_METHOD=rebase MERGE_ATTEMPT=direct)
  grep -qx -- "pr merge 12 --repo acme/app --rebase --delete-branch --match-head-commit $H" "$d.fx/merges.log" \
    && ok "[$SH] green CI, direct attempt: bound merge without --auto" || no "[$SH] direct merge args: $(cat "$d.fx/merges.log" 2>/dev/null)"

  echo "[$SH] merge method"
  d=$(repo "mm-$SH" app.js)
  fill "$TMP/method.sh" "$d.mm.sh" REPO=acme/app
  echo '{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true}' > "$d.fx/repo.json"
  printf '# P\n\n## Deploy Configuration (configured by /setup-deploy)\n- Platform: fly\n- Merge method: rebase\n\n## Other\n' > "$d/CLAUDE.md"
  out=$(run "$SH" "$d" "$d.mm.sh")
  case "$out" in *"MERGE_METHOD: rebase (from Deploy Configuration)"*) ok "[$SH] configured method wins over squash" ;; *) no "[$SH] configured method ignored: $out" ;; esac
  printf '## Deploy Configuration\n- Merge method: fast-forward\n' > "$d/CLAUDE.md"
  out=$(run "$SH" "$d" "$d.mm.sh"); rc=$?
  case "$out" in *MERGE_METHOD_UNKNOWN*) ok "[$SH] unknown configured method stops" ;; *) no "[$SH] unknown method: $out" ;; esac
  [ "$rc" != 0 ] && ok "[$SH] unknown method exits non-zero" || no "[$SH] unknown method exit 0"
  printf '## Deploy Configuration\n- Merge method: squash\n' > "$d/CLAUDE.md"
  echo '{"allow_squash_merge":false,"allow_merge_commit":true,"allow_rebase_merge":false}' > "$d.fx/repo.json"
  out=$(run "$SH" "$d" "$d.mm.sh")
  case "$out" in *MERGE_METHOD_DISALLOWED*) ok "[$SH] configured method the repo forbids stops" ;; *) no "[$SH] disallowed: $out" ;; esac
  rm -f "$d/CLAUDE.md"
  echo '{"allow_squash_merge":false,"allow_merge_commit":true,"allow_rebase_merge":true}' > "$d.fx/repo.json"
  out=$(run "$SH" "$d" "$d.mm.sh")
  case "$out" in *"MERGE_METHOD: merge (from repo settings)"*) ok "[$SH] unconfigured: first allowed method" ;; *) no "[$SH] detection: $out" ;; esac
  rm -f "$d.fx/repo.json"
  out=$(run "$SH" "$d" "$d.mm.sh"); rc=$?
  case "$out" in *MERGE_METHOD_UNKNOWN*) ok "[$SH] unreadable settings, nothing configured -> stop, no --merge guess" ;; *) no "[$SH] unreadable settings: $out" ;; esac

  echo "[$SH] merge readback"
  d=$(repo "r-$SH" app.js); H=$(git -C "$d" rev-parse HEAD)
  rbk() {  # rbk STATE HEAD AUTO QUEUE [overrides]
    printf '{"data":{"repository":{"pullRequest":{"state":"%s","headRefOid":"%s","baseRefName":"main","mergeCommit":%s,"autoMergeRequest":%s,"mergeQueueEntry":%s}}}}\n' \
      "$1" "$2" "$( [ "$1" = MERGED ] && echo '{"oid":"abc123"}' || echo null)" "$3" "$4" > "$d.fx/graphql.json"
    shift 4
    fill "$TMP/readback.sh" "$d.r.sh" REPO=acme/app PR_NUMBER=12 PR_HEAD="$H" BASE_BRANCH=main MERGE_ATTEMPT=none WAITED=false "$@"
    run "$SH" "$d" "$d.r.sh" | grep '^MERGE_ACTION'
  }
  [ "$(rbk OPEN "$H" null '{"state":"QUEUED"}' WAITED=true MERGE_ATTEMPT=auto)" = "MERGE_ACTION WAIT" ] \
    && ok "[$SH] OPEN with a queue entry -> still waiting" || no "[$SH] queued PR not WAIT"
  [ "$(rbk OPEN "$H" null null WAITED=true MERGE_ATTEMPT=auto)" = "MERGE_ACTION REMOVED" ] \
    && ok "[$SH] OPEN with nothing armed after waiting -> REMOVED" || no "[$SH] queue removal not detected"
  [ "$(rbk OPEN "$H" null null)" = "MERGE_ACTION START" ] && ok "[$SH] fresh OPEN -> START" || no "[$SH] start"
  [ "$(rbk OPEN "$H" null null MERGE_ATTEMPT=direct)" = "MERGE_ACTION STOP" ] && ok "[$SH] no fallback after a direct attempt" || no "[$SH] direct fallback"
  [ "$(rbk MERGED "$H" null null MERGE_ATTEMPT=auto)" = "MERGE_ACTION MERGED" ] && ok "[$SH] MERGED head -> MERGED" || no "[$SH] merged"
  [ "$(rbk OPEN 0123456789abcdef0123456789abcdef01234567 null null)" = "MERGE_ACTION HEAD_CHANGED" ] && ok "[$SH] moved head -> HEAD_CHANGED" || no "[$SH] readback head"
  # a rerun with the carried values left unfilled must not read as a fresh START
  printf '{"data":{"repository":{"pullRequest":{"state":"OPEN","headRefOid":"%s","baseRefName":"main","mergeCommit":null,"autoMergeRequest":null,"mergeQueueEntry":null}}}}\n' "$H" > "$d.fx/graphql.json"
  fill "$TMP/readback.sh" "$d.r.sh" REPO=acme/app PR_NUMBER=12 PR_HEAD="$H" BASE_BRANCH=main
  v=$(run "$SH" "$d" "$d.r.sh" | grep '^MERGE_ACTION')
  [ "$v" = "MERGE_ACTION UNKNOWN" ] && ok "[$SH] unfilled MERGE_ATTEMPT/WAITED -> UNKNOWN" || no "[$SH] unfilled readback values: $v"
  fill "$TMP/readback.sh" "$d.r.sh" REPO=acme/app PR_NUMBER=12 PR_HEAD="$H" BASE_BRANCH=main MERGE_ATTEMPT=none WAITED=false
  echo '{"errors":[{"message":"Field mergeQueueEntry does not exist"}]}' > "$d.fx/graphql.json"
  v=$(run "$SH" "$d" "$d.r.sh" | grep '^MERGE_ACTION')
  [ "$v" = "MERGE_ACTION UNKNOWN" ] && ok "[$SH] incomplete readback -> UNKNOWN" || no "[$SH] readback errors: $v"

  echo "[$SH] revert"
  # merge-commit landing: plain `git revert` would need -m
  d=$(repo "v-$SH" app.js)
  git -C "$d" checkout -q main && git -C "$d" merge -q --no-ff feature -m "Merge PR 12" && git -C "$d" push -q origin main
  MS=$(git -C "$d" rev-parse main); git -C "$d" checkout -q feature
  prjson "$d" MERGED x
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=merge
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" = 0 ] && case "$out" in *REVERT_SHA=*) true ;; *) false ;; esac && [ "$(git -C "$d" show HEAD:app.js)" = 'let a = 1' ]; then
    ok "[$SH] merge commit reverted with -m 1"
  else
    no "[$SH] merge-commit revert: rc=$rc $out"
  fi
  # dirty tree refused before touching anything
  d=$(repo "vd-$SH" app.js)
  git -C "$d" checkout -q main && git -C "$d" merge -q --no-ff feature -m "Merge PR 12" && git -C "$d" push -q origin main
  MS=$(git -C "$d" rev-parse main); git -C "$d" checkout -q feature; echo wip >> "$d/README.md"
  prjson "$d" MERGED x
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=merge
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" != 0 ] && case "$out" in *ROLLBACK_PENDING*) true ;; *) false ;; esac \
     && [ "$(git -C "$d" branch --show-current)" = feature ] && [ "$(git -C "$d" rev-parse main)" = "$MS" ]; then
    ok "[$SH] dirty tree: no checkout, no revert"
  else
    no "[$SH] dirty tree revert: rc=$rc $out"
  fi
  # rebase merge of two commits: the whole landed range goes
  d="$TMP/vr-$SH"; git init -q --bare "$d.git"; git init -q -b main "$d"; mkdir -p "$d.fx"
  ( cd "$d" && echo one > a.txt && git add -A && git commit -q -m init && git remote add origin "$d.git" \
    && echo two > a.txt && git commit -qam "first change" && echo three > b.txt && git add -A && git commit -qm "second change" \
    && git push -q origin main )
  MS=$(git -C "$d" rev-parse main)
  echo '{"commits":[{"messageHeadline":"first change"},{"messageHeadline":"second change"}]}' > "$d.fx/pr.json"
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=rebase
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" = 0 ] && [ "$(git -C "$d" show HEAD:a.txt)" = one ] && ! git -C "$d" cat-file -e HEAD:b.txt 2>/dev/null; then
    ok "[$SH] rebase merge: every landed commit reverted"
  else
    no "[$SH] rebase revert: rc=$rc $out"
  fi
  git -C "$d" reset -q --hard "$MS"
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=unknown
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" != 0 ] && [ "$(git -C "$d" rev-parse HEAD)" = "$MS" ]; then
    ok "[$SH] unknown shape of a multi-commit PR -> ROLLBACK_PENDING, nothing reverted"
  else
    no "[$SH] unknown shape: rc=$rc $out"
  fi
  # rebase merge whose landed subjects differ from the PR's commits: wrong range, no revert
  echo '{"commits":[{"messageHeadline":"first change"},{"messageHeadline":"some other change"}]}' > "$d.fx/pr.json"
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=rebase
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" != 0 ] && case "$out" in *ROLLBACK_PENDING*) true ;; *) false ;; esac && [ "$(git -C "$d" rev-parse HEAD)" = "$MS" ]; then
    ok "[$SH] rebase range whose subjects differ from the PR -> ROLLBACK_PENDING, nothing reverted"
  else
    no "[$SH] rebase subject mismatch: rc=$rc $out"
  fi

  echo "[$SH] test command"
  d=$(repo "tc-$SH" app.js)
  python3 -I - "$TMP/tests.sh" "$d.tc.sh" <<'PY'
import sys
t = open(sys.argv[1]).read().replace("<test command>", "sh -c 'echo boom; exit 3'")
open(sys.argv[2], "w").write(t)
PY
  out=$(run "$SH" "$d" "$d.tc.sh")
  case "$out" in *"TEST_EXIT=3 "*) ok "[$SH] failing suite's exit status is reported" ;; *) no "[$SH] test exit masked: $out" ;; esac
done

echo "static contract"
S="$SKILL"
grep -q 'bun test' "$S" && no "a bun test default survives" || ok "no bun test default"
grep -qi 'merge anyway' "$S" && no "'merge anyway' still offered" || ok "no 'merge anyway' option"
grep -q 'Do not ask the question below and do not offer A or C' "$S" && ok "blockers stop the gate" || no "blockers can still reach A/C"
grep -q 'gh pr view "$PR_NUMBER" --repo "$REPO" --json body -q .body | ~/.vibestack/bin/vibe-untrusted --source pr-body' "$S" \
  && ok "PR body goes through vibe-untrusted" || no "PR body read raw"
grep -q 'gh pr checks --watch' "$S" && no "unbounded gh pr checks --watch survives" || ok "no unbounded CI watch"
grep -q 'Mark it as healthy' "$S" && no "'Mark it as healthy' survives" || ok "accepted issues report DEGRADED"
grep -q 'production is untouched' "$S" && no "staging still promises production is untouched" || ok "no staging-first promise"
grep -q 'MERGED (UNVERIFIED)' "$S" && grep -q 'MERGED — NO DEPLOY NEEDED' "$S" && grep -q 'ROLLBACK PENDING' "$S" \
  && ok "verdict table has the honest outcomes" || no "verdict table incomplete"
grep -q '"status":"<SUCCESS/REVERTED/INCOMPLETE>"' "$S" && ok "JSONL status has INCOMPLETE" || no "JSONL status cannot say incomplete"
# Every gh merge/checks/view inside a bash block names the PR, except Step 1's
# one current-branch lookup.
python3 -I - "$S" > "$TMP/unbound.txt" <<'PY'
import re, sys
on = False
for line in open(sys.argv[1]).read().splitlines():
    s = line.strip()
    if s.startswith("```"):
        on = (not on) and s == "```bash"
        continue
    if on and re.search(r"\bgh pr (merge|checks|view)\b", line) and '"$PR_NUMBER"' not in line \
       and "PR_NUMBER=$(gh pr view --json number -q .number)" not in line and "gh pr view $PR_REF" not in line:
        print(line)
PY
[ -s "$TMP/unbound.txt" ] && no "gh pr commands not bound to the PR number: $(cat "$TMP/unbound.txt")" || ok "every gh pr command is bound to PR_NUMBER"
grep -E 'gh pr merge ' "$S" | grep -v -- '--match-head-commit' | grep -q 'gh pr merge "\$PR_NUMBER"' \
  && no "a gh pr merge without --match-head-commit" || ok "every merge carries --match-head-commit"
grep -q 'vibe-diff-scope <base>' "$S" && no "post-merge scope classification survives" || ok "scope classified once, before the merge"
fn() { awk '/^ci_gate\(\) \{/{on=1} on{print} on&&/^\}/{exit}' "$1"; }
fn "$TMP/gate.sh" > "$TMP/fn1"; fn "$TMP/merge.sh" > "$TMP/fn2"
[ -s "$TMP/fn1" ] && cmp -s "$TMP/fn1" "$TMP/fn2" && ok "Step 2 and the merge block run the same CI gate" || no "the two ci_gate copies differ"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
