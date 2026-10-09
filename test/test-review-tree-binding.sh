#!/usr/bin/env bash
# test-review-tree-binding.sh — reviews and test runs are keyed to content, not
# commits.
#
# Covers:
#   - vibe-evidence: a single-string command runs through the shell and is
#     recorded verbatim; --expect-cmd, --max-age and --allow-paths decide FRESH
#     vs STALE in both directions; --expect-cmd works without --label;
#   - the shared Review Readiness Dashboard snapshot: its bash block prints a
#     TREE_NOW that matches a clean review entry, and an edit after that entry
#     makes them differ (stale) while HEAD has not moved;
#   - /ship Step 5 records every lane in the ledger and Step 16 reuses a run of
#     identical content, executed end to end from the skill's own blocks;
#   - /codex binds its review record to the tree it started on;
#   - /land-and-deploy cites a FRESH ledger run before re-running the suite.
#
# Usage: test/test-review-tree-binding.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
BIN="$SRC/bin"
[ -x "$BIN/vibe-evidence" ] || { echo "not a repo root: $SRC" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VIBESTACK_HOME="$TMP/home"
export PYTHONDONTWRITEBYTECODE=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

# A fake HOME whose ~/.vibestack/bin is this checkout's bin/, so the skills'
# own blocks run unmodified against the code under test. Blocks resolve the
# state root as ${VIBESTACK_HOME:-$HOME/.vibestack}, so its bin/ links there too.
FH="$TMP/fakehome"
mkdir -p "$FH/.vibestack" "$VIBESTACK_HOME"
ln -s "$BIN" "$FH/.vibestack/bin"
ln -s "$BIN" "$VIBESTACK_HOME/bin"

REPO="$TMP/repo"
mkdir -p "$REPO"
(
  cd "$REPO" && git init -q -b feat && git config user.email t@example.com &&
  git config user.name t && printf 'a\n' > a.txt && printf '# log\n' > CHANGELOG.md &&
  mkdir -p docs && printf 'd\n' > docs/x.md && git add . && git commit -qm init
)
E="$BIN/vibe-evidence"
ev() { (cd "$REPO" && "$E" "$@"); }

echo "vibe-evidence: command lines"
OUT=$(ev run --skill t --label unit -- 'printf one && printf two' 2>&1); RC=$?
chk "a single-string command runs through the shell" "$OUT" "onetwo"
chk "and forwards its exit" "$RC" "0"
LEDGER=$(find "$VIBESTACK_HOME" -name evidence.jsonl | head -1)
REC=$(python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).readlines()[-1]); print(r["command"]); print(len(r.get("tree_full","")))' "$LEDGER")
chk "the command is recorded verbatim" "$(printf '%s\n' "$REC" | sed -n 1p)" "printf one && printf two"
[ "$(printf '%s\n' "$REC" | sed -n 2p)" -ge 40 ] && ok "the full tree id is recorded" || no "no full tree id in the record"
ev run --skill t --label exit3 -- 'exit 3' >/dev/null 2>&1; chk "a failing shell string forwards its status" "$?" "3"

echo "vibe-evidence: --expect-cmd"
ev check --label unit --expect-cmd 'printf one && printf two' >/dev/null; chk "the same command reads FRESH" "$?" "0"
ev check --label unit --expect-cmd 'printf one' >/dev/null; chk "a different command is not evidence" "$?" "1"
ev check --expect-cmd 'printf one && printf two' >/dev/null; chk "--expect-cmd alone is a valid check" "$?" "0"
ev check --expect-cmd 'never ran' >/dev/null; chk "an unrecorded command is STALE" "$?" "1"

echo "vibe-evidence: --max-age"
ev check --label unit --max-age 1 >/dev/null; chk "a fresh pass is inside the age bound" "$?" "0"
python3 -I - "$LEDGER" <<'PY'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
old = dict(rows[0], label="aged", ts="2001-01-01T00:00:00Z")
open(p, "a").write(json.dumps(old) + "\n")
PY
ev check --label aged >/dev/null; chk "without --max-age an old pass still counts" "$?" "0"
ev check --label aged --max-age 24 >/dev/null; chk "an old pass is STALE under --max-age" "$?" "1"
ev check --label unit --max-age nope >/dev/null 2>&1; chk "a non-numeric --max-age is a usage error" "$?" "2"

echo "vibe-evidence: --allow-paths"
printf '## 1.0\n' >> "$REPO/CHANGELOG.md"
ev check --label unit >/dev/null; chk "a CHANGELOG edit makes an exact check STALE" "$?" "1"
OUT=$(ev check --label unit --allow-paths CHANGELOG.md,VERSION); RC=$?
chk "an allow-listed CHANGELOG edit keeps it FRESH" "$RC" "0"
case "$OUT" in *"differs only in CHANGELOG.md"*) ok "and names what differs" ;; *) no "FRESH line does not name the diff: $OUT" ;; esac
(cd "$REPO" && git commit -qam bump)
ev check --label unit --allow-paths CHANGELOG.md >/dev/null; chk "committing the bookkeeping keeps it FRESH" "$?" "0"
printf 'more\n' >> "$REPO/docs/x.md"
ev check --label unit --allow-paths CHANGELOG.md >/dev/null; chk "a doc edit outside the list is STALE" "$?" "1"
ev check --label unit --allow-paths CHANGELOG.md,docs/ >/dev/null; chk "a directory prefix allows paths under it" "$?" "0"
ev check --label unit --allow-paths CHANGELOG.md,docs >/dev/null; chk "a bare name is not a directory prefix" "$?" "1"
printf 'b\n' >> "$REPO/a.txt"
ev check --label unit --allow-paths CHANGELOG.md,docs/ >/dev/null; chk "a source edit is STALE whatever the list says" "$?" "1"
(cd "$REPO" && git checkout -q -- a.txt docs/x.md)
python3 -I - "$LEDGER" <<'PY'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
gone = "0123456789abcdef0123456789abcdef01234567"
row = dict(rows[0], label="gcd", tree=gone[:12], tree_full=gone)
open(p, "a").write(json.dumps(row) + "\n")
PY
ev check --label gcd --allow-paths CHANGELOG.md,VERSION,docs/,a.txt >/dev/null
chk "a recorded tree the object store no longer has is STALE, never a match" "$?" "1"

echo "dashboard snapshot (shared snippet)"
SNIP="$SRC/lib/snippets/review-readiness-dashboard.md"
awk '/^```bash$/{f=1;next} /^```$/{if(f)exit} f' "$SNIP" > "$TMP/dash.sh"
grep -qF 'vibe-review-log --snapshot' "$TMP/dash.sh" && ok "the snippet snapshots the tree" || no "the snippet takes no snapshot"
dash_tree() { (cd "$REPO" && HOME="$FH" bash "$TMP/dash.sh" 2>/dev/null | sed -n 's/^TREE_NOW: //p'); }
(cd "$REPO" && "$BIN/vibe-review-log" '{"skill":"review","status":"clean","completed":true,"converged":true}' >/dev/null)
LOGGED=$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["tree"])' "$(find "$VIBESTACK_HOME/projects" -name '*-reviews.jsonl' | head -1)")
HEAD1=$(git -C "$REPO" rev-parse HEAD)
chk "a clean entry matches TREE_NOW" "$(dash_tree)" "$LOGGED"
printf 'edit after review\n' >> "$REPO/a.txt"
T2=$(dash_tree)
[ -n "$T2" ] && [ "$T2" != "$LOGGED" ] && ok "an edit after the clean entry makes it stale" || no "edit did not move TREE_NOW ($T2)"
chk "though HEAD has not moved" "$(git -C "$REPO" rev-parse HEAD)" "$HEAD1"
(cd "$REPO" && git checkout -q -- a.txt)
has_snip() { if grep -qF -- "$2" "$SNIP"; then ok "$1"; else no "$1 (missing: $2)"; fi; }
has_snip "the verdict binds to the tree" "tree changed since review"
has_snip "staleness compares trees first" 'compare it with `TREE_NOW`'
has_snip "a null tree never clears" 'CLEAN (freshness unknown)'
has_snip "an unverified entry is never clean" 'status `unverified`'
grep -qF 'CLEAN (freshness unknown)' "$SRC/skills/ship/SKILL.md" && ok "ship: a null tree never clears" || no "ship: null-tree rule missing"

echo "review log: clean without a tree fingerprint"
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
OUT=$(cd "$NOGIT" && "$BIN/vibe-review-log" '{"skill":"review","status":"clean","completed":true,"converged":true}' 2>&1); RC=$?
chk "a clean entry with no snapshot is still logged" "$RC" "0"
NLOG=$(find "$VIBESTACK_HOME/projects" -name 'unknown-reviews.jsonl' | head -1)
NREC=$(python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).readlines()[-1]); print(r["status"], r.get("requested_status"), r["tree"])' "$NLOG" 2>/dev/null)
chk "it is recorded as unverified, never clean" "$NREC" "unverified clean None"
case "$OUT" in *unverified*) ok "and the logger says so" ;; *) no "no unverified warning: $OUT" ;; esac

echo "ship: Step 5 records lanes, Step 16 reuses them"
SHIP="$SRC/skills/ship/SKILL.md"
section() { awk -v a="$1" -v b="$2" 'index($0,a)==1{on=1} on&&index($0,b)==1{exit} on' "$SHIP"; }
S5=$(section '## Step 5: Run tests' '## Test Failure Ownership Triage')
S16=$(section '## Step 16: Verification Gate' '## Step 17: Push')
printf '%s\n' "$S5" | awk '/^```bash$/{f=1;next} /^```$/{if(f)exit} f' > "$TMP/lanes.sh"
python3 -I - "$TMP/lanes.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("'<test command for lane 1>'", "'printf green'").replace("'<test command for lane 2>'", "'exit 3'")
t = t.replace("<lane1>", "unit").replace("<lane2>", "e2e")
open(p, "w").write(t)
PY
OUT=$(cd "$REPO" && HOME="$FH" bash "$TMP/lanes.sh" 2>&1)
case "$OUT" in *"LANE: unit exit=0 "*) ok "a passing lane reports exit=0 through the wrapper" ;; *) no "unit lane: $OUT" ;; esac
case "$OUT" in *"LANE: e2e exit=3 "*) ok "a failing lane keeps its own exit through the wrapper" ;; *) no "e2e lane: $OUT" ;; esac
printf '%s\n' "$S16" | awk '/^ *```bash$/{f=1;next} /^ *```$/{if(f)exit} f' | sed 's/^ *//' > "$TMP/gate.sh"
grep -qF 'vibe-evidence check' "$TMP/gate.sh" && ok "Step 16 checks the ledger" || no "Step 16 has no ledger check"
gate() { # gate LANE CMD -> exit of Step 16's own check line
  python3 -I - "$TMP/gate.sh" "$TMP/gate.$1.sh" "$1" "$2" <<'PY'
import sys
t = open(sys.argv[1]).read().replace("<lane>", sys.argv[3]).replace("<exact Step 5 command>", sys.argv[4])
open(sys.argv[2], "w").write(t)
PY
  (cd "$REPO" && HOME="$FH" bash "$TMP/gate.$1.sh" >/dev/null 2>&1)
}
gate unit 'printf green'; chk "Step 16 reuses the Step 5 pass on unchanged content" "$?" "0"
gate e2e 'exit 3'; chk "Step 16 never reuses a failed lane" "$?" "1"
printf '## 2.0\n' >> "$REPO/CHANGELOG.md"
gate unit 'printf green'; chk "release bookkeeping does not force a re-run" "$?" "0"
printf 'fix\n' >> "$REPO/a.txt"
gate unit 'printf green'; chk "a fix after Step 5 forces a re-run" "$?" "1"
(cd "$REPO" && git checkout -q -- a.txt CHANGELOG.md)
DASH=$(section '## Review Readiness Dashboard' '## Step 2:')
printf '%s' "$DASH" | grep -qF 'compare it with \`TREE_NOW\`' && ok "ship staleness compares trees first" || no "ship staleness still commit-only"

echo "ship: its own review records are bound to the tree they started on"
SH="$SRC/skills/ship/SKILL.md"
S9=$(section '## Step 9: Pre-Landing Review' '## Confidence Calibration')
printf '%s' "$S9" | grep -qF 'echo "START_TREE: $(${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log --snapshot' \
  && ok "Step 9 snapshots the tree before the diff" || no "Step 9 takes no start snapshot"
grep -F '"via":"ship"' "$SH" | grep -qF '"start_tree":"START_TREE"' \
  && ok "ship's review record carries start_tree" || no "ship's review record is not tree-bound"
grep -F '"skill":"adversarial-review"' "$SH" | grep -qF '"start_tree":"START_TREE"' \
  && ok "ship's adversarial record carries start_tree" || no "ship's adversarial record is not tree-bound"

echo "codex: review record bound to its start tree"
CX="$SRC/skills/codex/SKILL.md"
grep -qF 'echo "START_TREE: $(${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log --snapshot' "$CX" && ok "review mode snapshots before the run" || no "no start snapshot in review mode"
grep -qF '"skill":"codex-review","timestamp":"TIMESTAMP"' "$CX" && \
  grep -F '"skill":"codex-review","timestamp":"TIMESTAMP"' "$CX" | grep -qF '"completed":COMPLETED,"start_tree":"START_TREE"' \
  && ok "the review record carries completed and start_tree" || no "the review record is not tree-bound"
grep -F '"skill":"codex-review","status":"timeout"' "$CX" | grep -vqF '"completed":false' \
  && no "a timeout record does not say it is incomplete" || ok "timeout records say completed=false"

echo "land-and-deploy: cite a FRESH run first"
LD="$SRC/skills/land-and-deploy/SKILL.md"
T35=$(awk '/^### 3.5b: Test results/{on=1;next} on&&/^### /{exit} on' "$LD")
printf '%s' "$T35" | grep -qF "vibe-evidence check --expect-cmd '<test command>'" && ok "the gate consults the ledger" || no "the gate never consults the ledger"
FIRST=$(printf '%s\n' "$T35" | awk '/^```bash$/{f=1;next} /^```$/{if(f)exit} f')
printf '%s' "$FIRST" | grep -qF '_TEXIT=$?' && ok "the run block is still the first block" || no "the run block moved"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
