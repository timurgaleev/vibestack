#!/usr/bin/env bash
# test-investigate-contract.sh — contracts the /investigate skill text must keep.
#
# Covers:
#   - a feedback loop is built and run red before any hypothesis work, and the
#     LOOP completion line blocks Phase 2;
#   - Phase 1 ends in ranked, falsifiable hypotheses; Phase 3 changes one
#     variable per probe, reverts failed probes and tags every temporary log;
#   - Phase 4 writes the regression test at a real seam and runs it red
#     BEFORE the fix, under the shared test value bar;
#   - the DEBUG REPORT carries regression proof, the confirmed hypothesis and
#     a blast-radius block with an evidence rung;
#   - instrumentation is removed before the last run, and secrets are redacted
#     from repro commands, output and every written artifact;
#   - the LLM-agent branch bisects prompt revisions cheaply;
#   - the extra triggers live in frontmatter, not the description;
#   - Phase 2 points intermittent and CI-only failures at flake.md, and that
#     sub-doc keeps its recipe: base-vs-branch failure rates, a forced probe,
#     no loosened gates, order-dependent failures, races, and the
#     `Flake evidence` block.
#
# Usage: test/test-investigate-contract.sh [repo-root]
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

SOURCE="$SRC/skills/investigate/SKILL.md"
SKILL="$TMP/investigate/SKILL.md"
if VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SOURCE" "$SKILL" >/dev/null 2>&1; then
  ok "investigate renders"
else
  no "investigate renders"; echo "$pass passed, $fail failed"; exit 1
fi

has()   { if grep -qF -- "$2" "$SKILL"; then ok "$1"; else no "$1 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$SKILL"; then no "$1 (still present: $2)"; else ok "$1"; fi; }

# Byte offset of the first line containing a fixed string, after an optional
# starting line; empty when absent. Lets the suite assert ordering.
line_of() { awk -v n="$1" -v from="${2:-0}" 'NR > from && index($0, n) { print NR; exit }' "$SKILL"; }
before() {
  local a b
  a="$(line_of "$2")"; b="$(line_of "$3")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"; else no "$1 ('$2' line ${a:-none} not before '$3' line ${b:-none})"; fi
}

echo "feedback loop"
has    "Phase 1 builds a feedback loop"        '**Feedback loop:**'
# The ways to build a loop are checked inside the step itself, so a trigger
# phrase or a later mention elsewhere cannot satisfy them.
LOOP_STEP="$TMP/loop-step"
awk 'index($0, "**Feedback loop:**") {f=1} index($0, "**Minimise:**") {exit} f' "$SKILL" > "$LOOP_STEP"
for way in 'failing test' 'curl' 'snapshot diff' 'headless browser' 'trace replay' \
           'throwaway harness' 'fuzz loop' 'bisection' 'differential'; do
  if grep -qF -- "$way" "$LOOP_STEP"; then ok "loop option: $way"; else no "loop option: $way"; fi
done
has    "loop is fast, sharp, deterministic"    'fast, sharp and deterministic'
has    "flaky bugs raise the reproduction rate" 'raise the reproduction rate'
has    "stop rule names what to ask for"        'say exactly what you need'
has    "LOOP completion line"                  'LOOP: <command> — ran: yes — red on: <symptom>'
has    "LOOP line blocks Phase 2"              'No Phase 2 until the `LOOP:` line is printed'
has    "minimise the repro"                    '**Minimise:**'
before "loop is built before minimising"       '**Feedback loop:**' '**Minimise:**'
before "loop is built before Phase 2"          'LOOP: <command> — ran: yes' '## Phase 2: Pattern Analysis'
hasnt  "old soft reproduce step gone"          'If not, gather more evidence before proceeding.'

echo "instrumentation"
has    "boundary instrumentation in one run"   'every component boundary in one run'
has    "secrets logged only as SET/UNSET"      '`SET`/`UNSET`'
has    "temporary logs are tagged"             '[DEBUG-<short>]'
# Value: protects=the cleanup check runs with this run's tag and sees untracked files and the harness; fails_when=the grep keeps the literal placeholder or drops --untracked; why_new=the old row pinned the placeholder form; seam=none
has    "Phase 5 greps with this run's tag"     "TAG='<short>'"
has    "Phase 5 grep sees untracked files"     'git grep -n --untracked -F "[DEBUG-$TAG]"'
has    "the throwaway harness is deleted"      'Delete the throwaway harness'
has    "regression test outside the lock asks first" 'When the regression test belongs outside the locked directory'
has    "only scanner exit 1 means redact"      'only exit 1 means redact and re-scan'
has    "a scan that cannot run keeps the artifact here" 'Exit 2 (the scan could not run) or 127'
has    "only prompt-only revisions collapse"   'and whose model, tool and sampling settings match'
has    "loop-less outcomes are named"          'The only outcomes without a red loop are'
P4="$(awk 'index($0, "## Phase 4: Implementation") {f=1} index($0, "## Phase 5: Verification") {exit} f' "$SKILL")"
case "$P4" in *'**Test value bar.**'*) ok "the value bar renders inside Phase 4" ;; *) no "the value bar is not inside Phase 4" ;; esac
has    "the value card's home in /investigate" "value card goes in the regression test's header comment"
has    "last edit precedes last run"           'last edit precedes the last run'
# The scope lock can cover less than the instrumented files and the regression
# test, so it is released before the tagged lines are removed.
has    "Phase 5 releases the lock first"       '**Release the scope lock first:**'
before "lock released before cleanup"          '**Release the scope lock first:**' '**Remove instrumentation:**'
before "cleanup before fresh verification"     '**Remove instrumentation:**' '**Fresh verification:**'
hasnt  "lock no longer held through cleanup"   'run the terminal cleanup from **Scope Lock** now, before the report is final.'

echo "hypotheses"
has    "3-5 ranked falsifiable hypotheses"     '3-5 ranked, falsifiable hypotheses'
has    "ranked list shown once"                'Show the ranked list once'
has    "suppressed when spawned or headless"   '`SESSION_KIND` is `spawned` or `headless`'
has    "3-strike points at the remaining items" 'the hypotheses still untested'
has    "working example diff in Phase 2"       '**Working example diff:**'

echo "probes"
has    "one variable per probe"                'one variable per probe'
has    "failed probe reverted before the next" 'Revert a failed probe before the next one'
has    "git diff confirms the revert"          '`git diff` shows none of the probe'
has    "perf bugs baseline then bisect"        'record a baseline measurement first, then bisect against it with `git bisect run'
# Bisect checks out other revisions: probes and tagged logs must not ride along,
# and HEAD must come back before the fix is written.
has    "bisect starts from a clean tree"       'Bisect only from a clean tree'
has    "bisect is reset before continuing"     'git bisect reset'

echo "phase 4 order"
has    "regression test from the minimised repro" 'from the minimised repro'
has    "test sits at a correct seam"           'at a correct seam'
has    "no seam is a finding for /improve-arch" '`/improve-arch`'
has    "red on its own assertion"              'red on its own assertion'
before "regression test is written before the fix" 'Write the regression test' 'Fix the root cause, not the symptom.'
before "test runs red before the fix"          'red on its own assertion' 'Fix the root cause, not the symptom.'
before "full suite runs after the fix"         'Fix the root cause, not the symptom.' 'Run the full test suite.'
if grep -qxF '{{include lib/snippets/test-value-bar.md}}' "$SOURCE"; then
  ok "source includes the test value bar"
else
  no "source includes the test value bar"
fi
has    "value bar expands in the render"       '**Test value bar.**'

echo "debug report"
has    "report carries regression proof"       'Regression proof:'
has    "report names the confirmed hypothesis" 'Hypothesis confirmed:'
has    "empty fields say none with a reason"   'none: <reason>'
has    "report has a blast radius block"       'Blast radius:'
has    "evidence ladder"                       'said → file:line → walked → ran → reproduced'
has    "confirmed vs cleared risks"            'Cleared risks:'

echo "redaction"
has    "repro commands use env vars"           'environment variable'
has    "output shows <REDACTED>"               '<REDACTED>'
has    "only signal lines are pasted"          'signal lines only'
has    "written artifacts are scanned"         'vibe-redact" scan --file'
has    "learnings JSON is scanned too"         'learnings JSON'

echo "llm agent bisect"
has    "identical rendered prompts collapse"   'rendered prompt bytes are identical'
has    "cheapest deterministic scorer"         'cheapest deterministic scorer'
has    "paid judging on the boundary pair"     'boundary pair'

echo "triggers"
FM="$TMP/frontmatter"
awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$SOURCE" > "$FM"
for t in 'test fails' 'failing test' 'build is broken' 'stack trace'; do
  if grep -qxF "  - $t" "$FM"; then ok "trigger: $t"; else no "trigger: $t"; fi
done
DESC="$(awk '/^description:/ {f=1; next} f && /^[a-z-]+:/ {exit} f' "$FM")"
case "$DESC" in
  *'test fails'*|*'failing test'*|*'build is broken'*) no "triggers kept out of the description" ;;
  *) ok "triggers kept out of the description" ;;
esac

echo "flake recipe"
# The pointer must sit in Phase 2 itself, so a mention in the report template
# or the rules cannot stand in for it.
PHASE2="$TMP/phase2"
awk 'index($0, "## Phase 2: Pattern Analysis") {f=1} index($0, "## Phase 3: Hypothesis Testing") {exit} f' "$SKILL" > "$PHASE2"
for t in 'flake.md' 'intermittent' 'CI-only'; do
  if grep -qF -- "$t" "$PHASE2"; then ok "Phase 2 pointer: $t"; else no "Phase 2 pointer: $t"; fi
done

FLAKE="$SRC/skills/investigate/flake.md"
if [ -f "$FLAKE" ]; then
  ok "flake.md exists"
  # A sub-doc is symlinked, not rendered: an include would ship as raw text.
  if grep -qE '^\{\{include ' "$FLAKE"; then no "flake.md has no include directive"; else ok "flake.md has no include directive"; fi
  fl()  { if grep -qF -- "$2" "$FLAKE"; then ok "$1"; else no "$1 (missing: $2)"; fi; }
  fl "base vs branch failure rate"        'failed/N'
  fl "at least ten runs per side"         'N ≥ 10'
  fl "single-file test command in a loop" "project's single-file test command"
  fl "first moved headSha dated"          'gh run list'
  fl "headSha named"                      'headSha'
  fl "forced probe rule"                  'No probe, no cause.'
  fl "never loosen a gate"                'Never loosen'
  fl "relaxation states its odds"         'P(fail | regression)'
  fl "rerun needs a named outside cause"  'named outside cause'
  fl "timing fixed in the measurement"    'min/p50/p95/max'
  fl "order-dependent section"            '## Order-dependent failures'
  fl "victim alone vs after earlier files" 'alone, then after'
  fl "bisect the earlier files"           'bisect'
  fl "fix the polluter"                   'Fix the polluter'
  for leak in 'environment variable' 'working directory' 'exit code' 'singleton' 'mock' \
              'listening server' 'temp file' 'home-directory state' 'timer'; do
    fl "names what leaked: $leak" "$leak"
  done
  fl "races section"                      '## Races'
  fl "monotonic timestamps per actor"     'monotonic'
  fl "forced interleaving hook"           'test-only hook'
  fl "concurrent-writer invariant test"   'N ≥ 8'
  fl "smaller window is not a fix"        'A smaller check-then-act window is not a fix.'
  fl "atomic primitive fix shapes"        'atomic'
  fl "run alone / full suite / random"    'random order'
  fl "condition-based waiting"            'condition-based wait'
  fl "flake evidence block"               'Flake evidence:'
  fl "evidence goes in the DEBUG REPORT"  'DEBUG REPORT'
  # N=20 cannot tell a small branch rate from noise; a base run that measures
  # nothing must not read as 0/N.
  fl "0/N bounds the rate only below 3/N"  '`0/N` rules out only a rate above 3/N'
  fl "branch blamed only at 5/20 or more"  'at least 5/20'
  fl "the failing test must exist on base" 'must exist on the base'
  fl "base worktree resolves its own code" 'resolves its own code'
  fl "a run that cannot start is not a failure" 'exit 126 or 127'
  if grep -qF 'red only in CI' "$SRC/skills/investigate/SKILL.md"; then
    ok "Phase 1 sends a CI-only failure to flake.md instead of BLOCKED"
  else
    no "Phase 1 stops a CI-only failure before flake.md can be read"
  fi
  if grep -qF 'red on: <symptom> in CI run <run id>' "$SRC/skills/investigate/SKILL.md"; then
    ok "a CI-only failure has its own LOOP: line form"
  else
    no "the LOOP: gate still requires a local red run for a CI-only failure"
  fi
  fl "a failed base SETUP stops before any rate" 'SETUP failed in the base worktree — no base rate'
  # Value: protects=the base-rate block never leaves a registered worktree or its temp parent behind; fails_when=cleanup runs only on the happy path or forgets the mktemp parent; why_new=no row ran the block; seam=none (real git worktree)
  RB="$(awk '/^```bash$/ {on=1; buf=""; next} on && /^```$/ {on=0; if (index(buf, "git worktree add")) {printf "%s", buf; exit}; next} on {buf = buf $0 "\n"}' "$FLAKE")"
  # A bare `mktemp -d` ignores TMPDIR on some hosts, so the leftover check below needs the explicit template.
  case "$RB" in *'mktemp -d "${TMPDIR:-/tmp}/'*) ;; *) no "base-rate block makes its temp dir under \${TMPDIR:-/tmp}"; RB="" ;; esac
  if [ -n "$RB" ]; then
    FR="$TMP/flake-repo"; FT="$TMP/flake-tmp"; mkdir -p "$FR" "$FT"
    git -C "$FR" init -q -b main 2>/dev/null || { git -C "$FR" init -q && git -C "$FR" checkout -q -b main; }
    git -C "$FR" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
    for setup in true false; do
      printf '%s' "$RB" | sed -e "s|<single-file test command for the failing file, run from the repo root>|true|" \
        -e "s|<dependency install command for a fresh checkout, or true>|$setup|" -e "s|<base ref, e.g. origin/main>|main|" > "$TMP/rate.sh"
      (cd "$FR" && TMPDIR="$FT" bash "$TMP/rate.sh") > "$TMP/rate.out" 2>&1 || true
      wts="$(git -C "$FR" worktree list | wc -l | tr -d ' ')"
      left="$(ls -A "$FT")"
      [ "$wts" = 1 ] && [ -z "$left" ] && ok "base-rate block (SETUP $setup) removes its worktree and temp dir" \
        || no "base-rate block (SETUP $setup) left worktrees=$wts tmp=[$left]: $(tr '\n' '|' < "$TMP/rate.out")"
    done
  fi
  fsec() { awk -v h="$1" 'index($0, h) == 1 {f=1; next} f && /^## / {exit} f' "$FLAKE"; }
  insec() { if fsec "$1" | grep -qF -- "$3"; then ok "$2"; else no "$2 (missing in $1: $3)"; fi; }
  # Value: protects=each recipe rule lives in its own section; fails_when=a phrase survives only elsewhere in the file; why_new=these rows were whole-file substring checks; seam=none
  insec '## Order-dependent failures' "bisect the earlier files (in its section)" 'bisect the list of earlier files'
  insec '## Order-dependent failures' "names what leaked: mock (in its section)" 'mock or stub never restored'
  insec '## Order-dependent failures' "names what leaked: timer (in its section)" 'timer or interval'
  insec '## Races' "atomic primitive (in its section)" 'Fix with an atomic primitive'
  # Value: protects=intermittent failures are dated by the earliest red, not the newest green; fails_when=the last-green/first-red pair returns; why_new=new rule; seam=none
  fl "the earliest red and the green before it bracket the change" 'the earliest red run and the last green run before it'
  fl "per-revision rates when reds and greens interleave"          'per-revision failure rate'
  fl "cached test results are not replayed"                       '-count=1'
  fl "a CI-only failure runs the full suite before it is environmental" 'run the full suite locally first'
  fl "races prefer a real seam to a test-only hook"               'only when no real seam exists'
  fl "three retries are four attempts"                            'four attempts'
else
  no "flake.md exists"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
