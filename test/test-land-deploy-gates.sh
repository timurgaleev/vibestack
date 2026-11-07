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
#   - the CI gate also reads check suites (one still queued or running is PENDING)
#     and reports every-check-skipped as ALL_SKIPPED, which merges only like NO_CHECKS;
#   - untracked non-ignored files count as a dirty checkout;
#   - a HEAD_CHANGED / BASE_CHANGED readback with a request still armed demands a
#     disarm, and the disarm block cancels auto-merge / dequeues, then reads it back;
#   - the revert handles merge commits (-m 1) and rebase merges (the whole range),
#     reverts a single commit only when the shape is proven (one PR commit, or the
#     landed patch-id equals the PR diff's), never trusts the method on a queue
#     landing, and refuses a dirty tree;
#   - the VERSION drift block passes --exclude-pr and its value as two arguments
#     under zsh as well as bash;
#   - the test command's exit status survives (no pipe into tail);
#   - a scope helper that cannot classify the diff (SCOPE_UNAVAILABLE), fails
#     silently or is missing leaves the scope unknown, and stale SCOPE_* values
#     from the caller's shell never leak in;
#   - the Deploy Configuration parse keeps a URL's scheme (`https://`), and a
#     recorded `Deploy trigger:` command is surfaced, an automatic one is not;
#   - the deploy fingerprint covers any workflow carrying a deploy job, whatever
#     its file name, and the pre-approval facts list each deploy workflow's
#     branch filters and environment gates;
#   - the inline review's checklist resolves through the sibling review skill and
#     an unreadable one stops instead of passing;
#   - project eval evidence is N/A without a suite and counts only when a run
#     names the PR head;
#   - the deploy log goes through vibe-review-log with the PR branch named, and a
#     failed write says "not logged";
#   - Step 0 carries the shared base-branch-detect fallback verbatim;
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
block '**The disarm block.**' > "$TMP/disarm.sh" || no "no disarm block"
block '## Step 3.4: VERSION drift' > "$TMP/drift.sh" || no "no VERSION drift block"
block '### 1.5a: Deploy infrastructure detection' > "$TMP/infra.sh" || no "no 1.5a detection block"
block '## Step 5: Deploy strategy detection' > "$TMP/strategy.sh" || no "no Step 5 detection block"
block 'Check whether this project has been through a successful' > "$TMP/fp-check.sh" || no "no Step 1.5 fingerprint check block"
block 'Save the deploy config fingerprint' > "$TMP/fp-save.sh" || no "no 1.5e fingerprint save block"
block '### 3.5d-bis: What the merge deploys' > "$TMP/facts.sh" || no "no 3.5d-bis deploy-facts block"
block '**If A (quick checklist):**' > "$TMP/checklist.sh" || no "no inline-review checklist block"
block '**Project evals' > "$TMP/evals.sh" || no "no project-evals block"
block 'Log to the review dashboard' > "$TMP/log.sh" || no "no deploy-log block"

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
  "pr merge") printf '%s\n' "${args[*]}" >> "$FX/merges.log"
    case " ${args[*]} " in *" --disable-auto "*) [ -f "$FX/disarm.works" ] && cp "$FX/graphql-after-auto.json" "$FX/graphql.json" ;; esac
    exit "$(cat "$FX/merge.exit" 2>/dev/null || echo 0)" ;;
  "pr diff") serve pr.diff ;;
  "pr create") printf '%s\n' "${args[*]}" >> "$FX/creates.log" ;;
  api\ *)
    ep=""
    skip=0
    for a in "${args[@]:1}"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$a" in -f|-F|--field|--raw-field|-H) skip=1 ;; -*) ;; *) [ -z "$ep" ] && ep="$a" ;; esac
    done
    case "$ep" in
      graphql)
        case "${args[*]}" in
          *"query=mutation"*) printf '%s\n' "${args[*]}" >> "$FX/mutations.log"
            [ -f "$FX/disarm.works" ] && cp "$FX/graphql-after-queue.json" "$FX/graphql.json"
            echo '{}'; exit 0 ;;
        esac
        serve graphql.json; exit "$(cat "$FX/graphql.exit" 2>/dev/null || echo 0)" ;;
      repos/*/commits/*/check-runs*) serve check-runs.json ;;
      repos/*/commits/*/status*) serve status.json ;;
      repos/*/commits/*/check-suites*) serve check-suites.json ;;
      repos/*/*) serve repo.json ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin/gh" "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH"
# The skill calls helpers under ~/.vibestack/bin; point HOME at a fixture that
# serves this checkout's bin/, so the result never depends on what the machine
# running the test happens to have installed.
mkdir -p "$TMP/home/.vibestack"
ln -s "$ROOT/bin" "$TMP/home/.vibestack/bin"
export HOME="$TMP/home"

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
checks() {  # checks DIR RUNS_JSON_ARRAY STATUSES_JSON_ARRAY [SUITES_JSON_ARRAY]
  printf '{"check_runs":%s}\n' "$2" > "$1.fx/check-runs.json"
  printf '{"statuses":%s}\n' "$3" > "$1.fx/status.json"
  printf '{"check_suites":%s}\n' "${4:-[]}" > "$1.fx/check-suites.json"
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
  echo scratch > "$d/notes.txt"
  out=$(run "$SH" "$d" "$d.t.sh"); rc=$?
  case "$out" in *LOCAL_TARGET_MISMATCH*notes.txt*) ok "[$SH] untracked non-ignored file aborts" ;; *) no "[$SH] untracked file accepted: $out" ;; esac
  rm -f "$d/notes.txt"

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
  # green runs read while a suite is still queued: a partial snapshot, not PASS
  checks "$d" '[{"status":"completed","conclusion":"success","name":"build"}]' '[]' '[{"status":"completed","app":{"slug":"github-actions"}},{"status":"queued","app":{"slug":"github-actions"}}]'
  v=$(run "$SH" "$d" "$d.g.sh" | head -1)
  [ "$v" = "VERDICT PENDING $H" ] && ok "[$SH] a queued check suite -> PENDING, not PASS" || no "[$SH] queued suite: $v"
  checks "$d" '[{"status":"completed","conclusion":"success","name":"build"}]' '[]' '[{"status":"in_progress","app":{"slug":"ci-app"}}]'
  v=$(run "$SH" "$d" "$d.g.sh" | head -1)
  [ "$v" = "VERDICT PENDING $H" ] && ok "[$SH] an in-progress check suite -> PENDING" || no "[$SH] running suite: $v"
  checks "$d" '[{"status":"completed","conclusion":"success","name":"build"}]' '[]'; rm -f "$d.fx/check-suites.json"
  v=$(run "$SH" "$d" "$d.g.sh" | head -1)
  [ "$v" = "VERDICT ERROR $H" ] && ok "[$SH] unreadable check suites -> ERROR" || no "[$SH] suites api failure: $v"
  v=$(gate '[{"status":"completed","conclusion":"skipped","name":"build"},{"status":"completed","conclusion":"skipped","name":"deploy"}]' '[]')
  [ "$v" = "VERDICT ALL_SKIPPED $H" ] && ok "[$SH] every check skipped -> ALL_SKIPPED, not PASS" || no "[$SH] all skipped: $v"
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
  checks "$d" '[{"status":"completed","conclusion":"skipped","name":"build"}]' '[]'
  out=$(mb MERGE_METHOD=squash)
  case "$out" in *MERGE_REFUSED*) ok "[$SH] all checks skipped, not approved -> refused" ;; *) no "[$SH] merged over all-skipped CI: $out" ;; esac
  [ "$(merges "$d")" = 0 ] || no "[$SH] gh pr merge ran with every check skipped"
  : > "$d.fx/merges.log"
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
  echo scratch > "$d/untracked.txt"
  out=$(mb MERGE_METHOD=squash)
  case "$out" in *LOCAL_TARGET_MISMATCH*) ok "[$SH] untracked file in the checkout -> refused" ;; *) no "[$SH] untracked file at merge: $out" ;; esac
  [ "$(merges "$d")" = 0 ] || no "[$SH] merged with an untracked file in the checkout"
  : > "$d.fx/merges.log"
  rm -f "$d/untracked.txt"
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
  # a moved head with auto-merge still armed: the request must be disarmed, not just abandoned
  rbk OPEN 0123456789abcdef0123456789abcdef01234567 '{"enabledAt":"x"}' null WAITED=true MERGE_ATTEMPT=auto >/dev/null
  case "$(run "$SH" "$d" "$d.r.sh")" in *DISARM_REQUIRED*) ok "[$SH] HEAD_CHANGED with auto-merge armed -> DISARM_REQUIRED" ;; *) no "[$SH] armed request left behind on HEAD_CHANGED" ;; esac
  rbk OPEN 0123456789abcdef0123456789abcdef01234567 null null >/dev/null
  case "$(run "$SH" "$d" "$d.r.sh")" in *DISARM_REQUIRED*) no "[$SH] DISARM_REQUIRED with nothing armed" ;; *) ok "[$SH] nothing armed -> no disarm demanded" ;; esac
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
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=merge MERGE_PATH=direct
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
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=merge MERGE_PATH=direct
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
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=rebase MERGE_PATH=direct
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" = 0 ] && [ "$(git -C "$d" show HEAD:a.txt)" = one ] && ! git -C "$d" cat-file -e HEAD:b.txt 2>/dev/null; then
    ok "[$SH] rebase merge: every landed commit reverted"
  else
    no "[$SH] rebase revert: rc=$rc $out"
  fi
  git -C "$d" reset -q --hard "$MS"
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=unknown MERGE_PATH=direct
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" != 0 ] && [ "$(git -C "$d" rev-parse HEAD)" = "$MS" ]; then
    ok "[$SH] unknown shape of a multi-commit PR -> ROLLBACK_PENDING, nothing reverted"
  else
    no "[$SH] unknown shape: rc=$rc $out"
  fi
  # rebase merge whose landed subjects differ from the PR's commits: wrong range, no revert
  echo '{"commits":[{"messageHeadline":"first change"},{"messageHeadline":"some other change"}]}' > "$d.fx/pr.json"
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=rebase MERGE_PATH=direct
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" != 0 ] && case "$out" in *ROLLBACK_PENDING*) true ;; *) false ;; esac && [ "$(git -C "$d" rev-parse HEAD)" = "$MS" ]; then
    ok "[$SH] rebase range whose subjects differ from the PR -> ROLLBACK_PENDING, nothing reverted"
  else
    no "[$SH] rebase subject mismatch: rc=$rc $out"
  fi

  # squash assumed, rebase landed (a queue picks its own method): reverting the tip
  # alone would leave the first commit live
  d="$TMP/vq-$SH"; git init -q --bare "$d.git"; git init -q -b main "$d"; mkdir -p "$d.fx"
  ( cd "$d" && echo one > a.txt && git add -A && git commit -q -m init && git remote add origin "$d.git" \
    && echo two > a.txt && git commit -qam "first change" && echo three > b.txt && git add -A && git commit -qm "second change" \
    && git push -q origin main )
  MS=$(git -C "$d" rev-parse main)
  echo '{"commits":[{"messageHeadline":"first change"},{"messageHeadline":"second change"}]}' > "$d.fx/pr.json"
  git -C "$d" diff "$MS~2" "$MS" > "$d.fx/pr.diff"
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=squash MERGE_PATH=queue
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" != 0 ] && case "$out" in *ROLLBACK_PENDING*) true ;; *) false ;; esac && [ "$(git -C "$d" rev-parse HEAD)" = "$MS" ]; then
    ok "[$SH] queue landing assumed squash but rebased -> ROLLBACK_PENDING, nothing reverted"
  else
    no "[$SH] queue partial revert: rc=$rc $out"
  fi
  git -C "$d" reset -q --hard "$MS"
  fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=squash MERGE_PATH=direct
  out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
  if [ "$rc" != 0 ] && [ "$(git -C "$d" rev-parse HEAD)" = "$MS" ]; then
    ok "[$SH] squash method but the tip is not the PR's whole diff -> no single-commit revert"
  else
    no "[$SH] unproven squash reverted: rc=$rc $out"
  fi
  # a real squash of a two-commit PR: the landed patch is the PR diff, so it is proven
  d="$TMP/vs-$SH"; git init -q --bare "$d.git"; git init -q -b main "$d"; mkdir -p "$d.fx"
  ( cd "$d" && echo one > a.txt && git add -A && git commit -q -m init && git remote add origin "$d.git" \
    && echo two > a.txt && echo three > b.txt && git add -A && git commit -qm "Add thing (#12)" && git push -q origin main )
  MS=$(git -C "$d" rev-parse main)
  echo '{"commits":[{"messageHeadline":"first change"},{"messageHeadline":"second change"}]}' > "$d.fx/pr.json"
  git -C "$d" diff "$MS~1" "$MS" > "$d.fx/pr.diff"
  for P in direct queue; do
    git -C "$d" reset -q --hard "$MS"
    fill "$TMP/revert.sh" "$d.v.sh" REPO=acme/app PR_NUMBER=12 BASE_BRANCH=main MERGE_SHA="$MS" MERGE_METHOD=squash MERGE_PATH=$P
    out=$(run "$SH" "$d" "$d.v.sh"); rc=$?
    if [ "$rc" = 0 ] && [ "$(git -C "$d" show HEAD:a.txt)" = one ] && ! git -C "$d" cat-file -e HEAD:b.txt 2>/dev/null; then
      ok "[$SH] squash proven by patch-id ($P path) -> reverted"
    else
      no "[$SH] proven squash ($P): rc=$rc $out"
    fi
  done

  echo "[$SH] disarm"
  d=$(repo "da-$SH" app.js)
  armed() {  # armed AUTO QUEUE -> graphql.json
    printf '{"data":{"repository":{"pullRequest":{"id":"PR_kw12","state":"OPEN","autoMergeRequest":%s,"mergeQueueEntry":%s}}}}\n' "$1" "$2"
  }
  fill "$TMP/disarm.sh" "$d.da.sh" REPO=acme/app PR_NUMBER=12
  armed '{"enabledAt":"x"}' null > "$d.fx/graphql.json"; armed null null > "$d.fx/graphql-after-auto.json"; touch "$d.fx/disarm.works"
  out=$(run "$SH" "$d" "$d.da.sh"); rc=$?
  if [ "$rc" = 0 ] && grep -qx -- 'pr merge 12 --repo acme/app --disable-auto' "$d.fx/merges.log" 2>/dev/null && case "$out" in *DISARMED*) true ;; *) false ;; esac; then
    ok "[$SH] armed auto-merge -> --disable-auto, read back, DISARMED"
  else
    no "[$SH] auto-merge not disarmed: rc=$rc $out"
  fi
  rm -f "$d.fx/merges.log"
  armed null '{"state":"QUEUED"}' > "$d.fx/graphql.json"; armed null null > "$d.fx/graphql-after-queue.json"
  out=$(run "$SH" "$d" "$d.da.sh"); rc=$?
  if [ "$rc" = 0 ] && grep -q 'dequeuePullRequest' "$d.fx/mutations.log" 2>/dev/null && grep -q 'id=PR_kw12' "$d.fx/mutations.log" && case "$out" in *DISARMED*) true ;; *) false ;; esac; then
    ok "[$SH] queue entry -> dequeuePullRequest for the PR node, DISARMED"
  else
    no "[$SH] queue entry not dequeued: rc=$rc $out"
  fi
  rm -f "$d.fx/disarm.works"
  armed '{"enabledAt":"x"}' null > "$d.fx/graphql.json"
  out=$(run "$SH" "$d" "$d.da.sh"); rc=$?
  case "$out" in *DISARM_FAILED*) [ "$rc" != 0 ] && ok "[$SH] still armed after the cancel -> DISARM_FAILED" || no "[$SH] DISARM_FAILED exit 0" ;; *) no "[$SH] failed disarm not reported: $out" ;; esac
  rm -f "$d.fx/graphql.json"
  out=$(run "$SH" "$d" "$d.da.sh"); rc=$?
  case "$out" in *DISARM_FAILED*) ok "[$SH] unreadable PR -> DISARM_FAILED, not DISARMED" ;; *) no "[$SH] unreadable disarm state: $out" ;; esac

  echo "[$SH] VERSION drift"
  d=$(repo "dr-$SH" app.js); H=$(git -C "$d" rev-parse HEAD)
  mkdir -p "$TMP/home-$SH/.vibestack/bin"
  cat > "$TMP/home-$SH/.vibestack/bin/vibe-next-version" <<'NV'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$NV_ARGS"
for a in "$@"; do case "$a" in --*" "*) echo "unknown flag: $a" >&2; exit 2 ;; esac; done
echo '{"version":"0.0.1","offline":false}'
NV
  chmod +x "$TMP/home-$SH/.vibestack/bin/vibe-next-version"
  _drift=$(cat "$TMP/drift.sh"); _drift=${_drift//<PR_NUMBER>/12}; _drift=${_drift//<PR_HEAD>/$H}
  _drift=${_drift//<BASE_BRANCH>/main}; _drift=${_drift//<BASE_SHA>/$(git -C "$d" rev-parse main)}
  { printf '%s\n' "$_drift"; echo 'echo "DRIFT OFFLINE=$OFFLINE NEXT=$NEXT_SLOT"'; } > "$d.dr.sh"
  out=$( cd "$d" && env -u PR_NUMBER -u PR_HEAD -u BASE_BRANCH -u BASE_SHA HOME="$TMP/home-$SH" NV_ARGS="$d.args" "$SH" "$d.dr.sh" 2>&1 )
  if case "$out" in *"DRIFT OFFLINE=false NEXT=0.0.1"*) true ;; *) false ;; esac && grep -A1 -x -- '--exclude-pr' "$d.args" | tail -1 | grep -qx 12; then
    ok "[$SH] --exclude-pr and the PR number reach vibe-next-version as two arguments"
  else
    no "[$SH] drift check went offline: $out / args: $(tr '\n' ' ' < "$d.args" 2>/dev/null)"
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

  echo "[$SH] deploy report location"
  d=$(repo "rp-$SH" app.js)
  block "Create the deploy report directory:" > "$d.rp.sh" || no "[$SH] report-dir block not found"
  out=$(run "$SH" "$d" "$d.rp.sh")
  rdir=$(printf '%s\n' "$out" | sed -n 's/^REPORT_DIR: //p')
  case "$rdir" in "$HOME/.vibestack/projects/"*/deploy-reports) [ -d "$rdir" ] && ok "[$SH] reports go under the state root" || no "[$SH] report dir not created: $rdir" ;;
    *) no "[$SH] report dir outside the state root: $out" ;; esac
  [ -z "$(git -C "$d" status --porcelain)" ] && ok "[$SH] report dir leaves the work tree clean" || no "[$SH] report dir dirtied the checkout: $(git -C "$d" status --porcelain)"

  # Value: protects=an unclassifiable diff never shrinks the canary; fails_when=the
  # SCOPE_UNAVAILABLE line is ignored or a caller's exported SCOPE_* survives the eval;
  # why_new=the Step 1 rows above only run the real helper on a readable diff; seam=none
  echo "[$SH] Step 1: scope helper unavailable"
  d=$(repo "su-$SH" README.md); H=$(git -C "$d" rev-parse HEAD); prjson "$d" OPEN "$H"
  mkdir -p "$TMP/su-vh-$SH/bin"
  printf '#!/usr/bin/env bash\necho SCOPE_UNAVAILABLE=true\nexit 2\n' > "$TMP/su-vh-$SH/bin/vibe-diff-scope"
  chmod +x "$TMP/su-vh-$SH/bin/vibe-diff-scope"
  fill "$TMP/target.sh" "$d.t.sh" PR_NUMBER=12
  out=$( cd "$d" && FX="$d.fx" SCOPE_FRONTEND=true SCOPE_DOCS=true VIBESTACK_HOME="$TMP/su-vh-$SH" "$SH" "$d.t.sh" 2>&1 )
  case "$out" in *"SCOPE KNOWN=false DOCS_ONLY=false FRONTEND=false BACKEND=false CONFIG=false DOCS=false"*) ok "[$SH] SCOPE_UNAVAILABLE -> scope unknown, never docs-only, no stale flags" ;;
    *) no "[$SH] unavailable scope read as known: $(printf '%s\n' "$out" | grep '^SCOPE')" ;; esac
  # A helper that crashes silently or is not installed prints nothing; an empty
  # classification must read as unknown, not as "known, nothing touched".
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/su-vh-$SH/bin/vibe-diff-scope"
  out=$( cd "$d" && FX="$d.fx" VIBESTACK_HOME="$TMP/su-vh-$SH" "$SH" "$d.t.sh" 2>&1 )
  case "$out" in *"SCOPE KNOWN=false DOCS_ONLY=false"*) ok "[$SH] silent helper failure -> scope unknown" ;;
    *) no "[$SH] silent helper failure read as known: $(printf '%s\n' "$out" | grep '^SCOPE')" ;; esac
  mkdir -p "$TMP/su-none-$SH"
  out=$( cd "$d" && FX="$d.fx" VIBESTACK_HOME="$TMP/su-none-$SH" "$SH" "$d.t.sh" 2>&1 )
  case "$out" in *"SCOPE KNOWN=false DOCS_ONLY=false"*) ok "[$SH] missing helper -> scope unknown" ;;
    *) no "[$SH] missing helper read as known: $(printf '%s\n' "$out" | grep '^SCOPE')" ;; esac

  echo "[$SH] Deploy Configuration parsing"
  d=$(repo "dc-$SH" app.js)
  cat > "$d/CLAUDE.md" <<'MD'
# App

## Deploy Configuration (configured by /setup-deploy)
- Platform: fly
- Production URL: https://app.example.com
- Deploy workflow: auto-deploy on push
- Merge method: squash

### Custom deploy hooks
- Pre-merge: none
- Deploy trigger: ./scripts/deploy.sh production
- Deploy status: fly status --app app
- Health check: https://app.example.com/health
MD
  for b in infra strategy; do
    out=$(run "$SH" "$d" "$TMP/$b.sh")
    case "$out" in *"PERSISTED_URL:https://app.example.com"*) ok "[$SH] $b: the persisted URL keeps https://" ;; *) no "[$SH] $b: URL mangled: $(printf '%s\n' "$out" | grep PERSISTED_URL)" ;; esac
    case "$out" in *"PERSISTED_PLATFORM:fly"*) ok "[$SH] $b: platform parsed" ;; *) no "[$SH] $b: platform: $(printf '%s\n' "$out" | grep PERSISTED_PLATFORM)" ;; esac
  done
  out=$(run "$SH" "$d" "$TMP/strategy.sh")
  case "$out" in *"DEPLOY_TRIGGER_COMMAND: ./scripts/deploy.sh production"*) ok "[$SH] a recorded deploy-trigger command is surfaced" ;; *) no "[$SH] trigger command not surfaced: $out" ;; esac
  sed 's|^- Deploy trigger: .*|- Deploy trigger: automatic on push to main|' "$d/CLAUDE.md" > "$d/CLAUDE.md.n" && mv "$d/CLAUDE.md.n" "$d/CLAUDE.md"
  out=$(run "$SH" "$d" "$TMP/strategy.sh")
  case "$out" in *DEPLOY_TRIGGER_COMMAND*) no "[$SH] an automatic trigger read as a command: $out" ;; *) ok "[$SH] an automatic trigger is not a command" ;; esac

  echo "[$SH] deploy fingerprint and pre-approval facts"
  d=$(repo "fp-$SH" app.js)
  mkdir -p "$d/.github/workflows"
  printf 'name: Release\non:\n  push:\n    branches: [main]\njobs:\n  deploy-prod:\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: ./deploy.sh\n' > "$d/.github/workflows/release.yml"
  printf 'name: CI\non: [pull_request]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make test\n' > "$d/.github/workflows/ci.yml"
  printf '## Deploy Configuration (configured by /setup-deploy)\n- Platform: fly\n- Production URL: https://app.example.com\n' > "$d/CLAUDE.md"
  run "$SH" "$d" "$TMP/fp-save.sh" >/dev/null
  out=$(run "$SH" "$d" "$TMP/fp-check.sh")
  case "$out" in *CONFIRMED*) ok "[$SH] saved fingerprint reads back CONFIRMED" ;; *) no "[$SH] fresh fingerprint: $out" ;; esac
  echo '# comment' >> "$d/.github/workflows/ci.yml"
  out=$(run "$SH" "$d" "$TMP/fp-check.sh")
  case "$out" in *CONFIRMED*) ok "[$SH] a non-deploy workflow edit keeps CONFIRMED" ;; *) no "[$SH] ci.yml edit: $out" ;; esac
  echo '      - run: ./notify.sh' >> "$d/.github/workflows/release.yml"
  out=$(run "$SH" "$d" "$TMP/fp-check.sh")
  case "$out" in *CONFIG_CHANGED*) ok "[$SH] editing release.yml (a deploy job) -> CONFIG_CHANGED" ;; *) no "[$SH] deploy job in release.yml not fingerprinted: $out" ;; esac
  ( cd "$d" && git add -A && git commit -q -m workflows )   # the facts read PR_HEAD's tree
  fill "$TMP/facts.sh" "$d.facts.sh" PR_HEAD="$(git -C "$d" rev-parse HEAD)"
  out=$(run "$SH" "$d" "$d.facts.sh")
  if case "$out" in *release.yml*"branches: [main]"*) true ;; *) false ;; esac && case "$out" in *release.yml*"environment: production"*) true ;; *) false ;; esac; then
    ok "[$SH] deploy facts list release.yml's branch filter and environment gate"
  else
    no "[$SH] deploy facts incomplete: $out"
  fi
  case "$out" in *ci.yml*) no "[$SH] a non-deploy workflow listed as deploying" ;; *) ok "[$SH] ci.yml is not listed as a deploy" ;; esac
  case "$out" in *"Platform: fly"*) ok "[$SH] deploy facts carry the Deploy Configuration" ;; *) no "[$SH] Deploy Configuration missing from facts: $out" ;; esac

  # Value: protects=the inline review fails closed; fails_when=a missing checklist prints
  # a note and the review "passes", or the path is pinned to ~/.claude; why_new=no row ran
  # this block; seam=none
  echo "[$SH] inline review checklist"
  sk="$TMP/sk-$SH"; mkdir -p "$sk/land-and-deploy"
  out=$( cd "$TMP" && CLAUDE_SKILL_DIR="$sk/land-and-deploy" "$SH" "$TMP/checklist.sh" 2>&1 ); rc=$?
  case "$out" in *CHECKLIST_UNREADABLE*) [ "$rc" != 0 ] && ok "[$SH] unreadable checklist -> CHECKLIST_UNREADABLE, non-zero" || no "[$SH] unreadable checklist exit 0" ;;
    *) no "[$SH] unreadable checklist not a stop: rc=$rc $out" ;; esac
  mkdir -p "$sk/review"; printf '# Pre-landing checklist\n- CHECK-ITEM-1 SQL safety\n' > "$sk/review/checklist.md"
  out=$( cd "$TMP" && CLAUDE_SKILL_DIR="$sk/land-and-deploy" "$SH" "$TMP/checklist.sh" 2>&1 ); rc=$?
  case "$out" in *CHECK-ITEM-1*) [ "$rc" = 0 ] && ok "[$SH] the sibling review checklist resolves and reads" || no "[$SH] readable checklist exit $rc" ;;
    *) no "[$SH] sibling checklist not read: rc=$rc $out" ;; esac

  echo "[$SH] project evals"
  d=$(repo "ev-$SH" app.js); H=$(git -C "$d" rev-parse HEAD)
  fill "$TMP/evals.sh" "$d.ev.sh" PR_HEAD="$H"
  out=$(run "$SH" "$d" "$d.ev.sh")
  case "$out" in *"PROJECT_EVALS: N/A"*) ok "[$SH] no eval suite -> N/A, not a warning" ;; *) no "[$SH] no suite: $out" ;; esac
  for u in chat search rank judge; do mkdir -p "$d/evals/$u"; echo '{}' > "$d/evals/$u/config.json"; done
  ( cd "$d" && git add -A && git commit -q -m evals )
  H=$(git -C "$d" rev-parse HEAD); H7=$(printf '%s' "$H" | cut -c1-7)
  mkdir -p "$d/evals/chat/runs" "$d/evals/search/runs" "$d/evals/judge/runs"
  printf '# chat eval\nHead: %s\npass 10/10\n' "$H7" > "$d/evals/chat/runs/summary-20261107T100000.md"
  printf '# search eval\npass 9/10\n' > "$d/evals/search/runs/summary-20261107T100000.md"
  printf 'INCOMPLETE: 3/5 runs (cost cap)\nHead: %s\n' "$H7" > "$d/evals/judge/runs/summary-20261107T100000.md"
  fill "$TMP/evals.sh" "$d.ev.sh" PR_HEAD="$H"
  out=$(run "$SH" "$d" "$d.ev.sh")
  case "$out" in *"EVAL evals/chat TIED"*) ok "[$SH] a run naming the head counts" ;; *) no "[$SH] tied run: $out" ;; esac
  case "$out" in *"EVAL evals/search UNTIED"*) ok "[$SH] a run not naming the head is untied" ;; *) no "[$SH] untied run: $out" ;; esac
  case "$out" in *"EVAL evals/rank NOT_RUN"*) ok "[$SH] a configured unit with no run is NOT_RUN" ;; *) no "[$SH] not-run unit: $out" ;; esac
  case "$out" in *"EVAL evals/judge INCOMPLETE"*) ok "[$SH] an INCOMPLETE run is never a pass" ;; *) no "[$SH] incomplete run: $out" ;; esac
  case "$out" in *"PROJECT_EVALS: N/A"*) no "[$SH] configured suite reported N/A" ;; *) ok "[$SH] configured suite is not N/A" ;; esac

  echo "[$SH] deploy log"
  d=$(repo "lg-$SH" app.js); H=$(git -C "$d" rev-parse HEAD); prjson "$d" MERGED "$H"
  git -C "$d" checkout -q main; M=$(git -C "$d" rev-parse HEAD); M7=$(printf '%s' "$M" | cut -c1-7)
  vh="$TMP/lg-vh-$SH"; mkdir -p "$vh"; ln -s "$ROOT/bin" "$vh/bin"
  logrun() {  # logrun ENTRY
    python3 -I - "$TMP/log.sh" "$d.lg.sh" "$M" "$1" <<'PY'
import sys
t = open(sys.argv[1]).read()
for k, v in (("<REPO>", "acme/app"), ("<PR_NUMBER>", "12"), ("<MERGE_SHA>", sys.argv[3]), ("<ENTRY>", sys.argv[4])):
    t = t.replace(k, v)
open(sys.argv[2], "w").write(t)
PY
    ( cd "$d" && FX="$d.fx" VIBESTACK_HOME="$vh" "$SH" "$d.lg.sh" ) 2>&1
  }
  out=$(logrun '{"skill":"land-and-deploy","status":"SUCCESS","verdict":"DEPLOYED AND VERIFIED","pr":12,"dry_run_s":0}'); rc=$?
  lf=$(find "$vh/projects" -name '*-reviews.jsonl' 2>/dev/null | head -1)
  if [ "$rc" = 0 ] && case "$out" in *"DEPLOY_LOG: logged"*) true ;; *) false ;; esac && [ -n "$lf" ] \
     && tail -1 "$lf" | jq -e --arg c "$M7" '.skill == "land-and-deploy" and .branch == "feature" and .commit == $c' >/dev/null; then
    ok "[$SH] deploy entry written through vibe-review-log with the PR branch and merge commit"
  else
    no "[$SH] deploy entry not logged: rc=$rc $out / $(tail -1 "$lf" 2>/dev/null)"
  fi
  out=$(logrun 'not json'); rc=$?
  case "$out" in *"DEPLOY_LOG: not logged"*) [ "$rc" != 0 ] && ok "[$SH] a failed write says not logged" || no "[$SH] failed write exit 0" ;; *) no "[$SH] failed write unreported: $out" ;; esac
done

echo "static contract"
S="$SKILL"
grep -q 'bun test' "$S" && no "a bun test default survives" || ok "no bun test default"
grep -qi 'merge anyway' "$S" && no "'merge anyway' still offered" || ok "no 'merge anyway' option"
grep -q 'Do not ask the question below and do not offer A or C' "$S" && ok "blockers stop the gate" || no "blockers can still reach A/C"
grep -qF 'gh pr view "$PR_NUMBER" --repo "$REPO" --json body -q .body | "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-untrusted" --source pr-body' "$S" \
  && ok "PR body goes through vibe-untrusted" || no "PR body read raw"
grep -q 'gh pr checks --watch' "$S" && no "unbounded gh pr checks --watch survives" || ok "no unbounded CI watch"
grep -q 'Mark it as healthy' "$S" && no "'Mark it as healthy' survives" || ok "accepted issues report DEGRADED"
grep -q 'production is untouched' "$S" && no "staging still promises production is untouched" || ok "no staging-first promise"
grep -q 'MERGED (UNVERIFIED)' "$S" && grep -q 'MERGED — NO DEPLOY NEEDED' "$S" && grep -q 'ROLLBACK PENDING' "$S" \
  && ok "verdict table has the honest outcomes" || no "verdict table incomplete"
grep -q '"status":"<SUCCESS/REVERTED/INCOMPLETE>"' "$S" && ok "JSONL status has INCOMPLETE" || no "JSONL status cannot say incomplete"
grep -q '"dry_run_s":<N>' "$S" && ok "JSONL entry records dry_run_s" || no "JSONL entry has no dry_run_s"
grep -q 'to verify the deploy worked' "$S" && no "1.5b still promises HTTP checks verify the deploy" || ok "1.5b promises reachability only"
grep -q 'not which revision it serves' "$S" && ok "1.5b says HTTP checks prove reachability, not the revision" || no "1.5b reachability note missing"
grep -q 'no E2E tests run today' "$S" && no "permanent 'no E2E tests run today' warning survives" || ok "no permanent E2E warning"
grep -q 'vibestack}/evals/' "$S" && no "evals read from the global state root, not the project" || ok "evals read from the project's own evals/"
grep -q 'Inline fix: <yes' "$S" && no "report can still claim inline fixes merged" || ok "no 'Inline fix: yes' report row"
grep -q 'stopped before merge' "$S" && ok "inline fixes report as stopped before merge" || no "inline fixes not 'stopped before merge'"
grep -qi 'push them, wait for CI' "$S" && ok "inline fixes: commit, push, wait for CI, rerun" || no "inline fix recovery skips push / CI"
grep -q 'production has not moved yet' "$S" && ok "a recorded trigger command says production has not moved" || no "no recorded-trigger rule in Step 5"
[ "$(grep -c 'MERGE WILL DEPLOY:' "$S")" -ge 2 ] && ok "MERGE WILL DEPLOY row in the report and the approval re-ground" || no "MERGE WILL DEPLOY not in both report and question"
python3 -I - "$ROOT/lib/snippets/base-branch-detect.md" "$S" <<'PY' && ok "Step 0 carries the base-branch-detect fallback verbatim" || no "Step 0 fallback is not the shared snippet"
import sys
snip, skill = open(sys.argv[1]).read(), open(sys.argv[2]).read()
a = snip.index("```bash\n"); b = snip.index("\n```", a + 8)
sys.exit(0 if snip[a:b] in skill else 1)
PY
grep -q "sed 's|refs/remotes/origin/||'" "$S" && no "the old inline base fallback survives" || ok "no old inline base fallback"
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
grep -E 'gh pr merge ' "$S" | grep -v -- '--match-head-commit' | grep -v -- '--disable-auto' | grep -q 'gh pr merge "\$PR_NUMBER"' \
  && no "a gh pr merge without --match-head-commit" || ok "every merge carries --match-head-commit"
grep -q '\.vibestack/deploy-reports' "$S" && no "deploy reports still written into the work tree" || ok "no deploy report path in the work tree"
grep -q 'vibe-diff-scope <base>' "$S" && no "post-merge scope classification survives" || ok "scope classified once, before the merge"
fn() { awk '/^ci_gate\(\) \{/{on=1} on{print} on&&/^\}/{exit}' "$1"; }
fn "$TMP/gate.sh" > "$TMP/fn1"; fn "$TMP/merge.sh" > "$TMP/fn2"
[ -s "$TMP/fn1" ] && cmp -s "$TMP/fn1" "$TMP/fn2" && ok "Step 2 and the merge block run the same CI gate" || no "the two ci_gate copies differ"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
