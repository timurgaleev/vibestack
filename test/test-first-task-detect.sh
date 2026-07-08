#!/usr/bin/env bash
# Smoke test for bin/vibe-first-task-detect — asserts each bucket the detector
# emits from a synthetic git repo. Fail-safe contract: unknown state → no output.
set -uo pipefail

BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/vibe-first-task-detect"
PASS=0; FAIL=0
_t() { # _t <expected> <description>
  local got exp="$1" desc="$2"; got=$("$BIN" 2>/dev/null)
  if [ "$got" = "$exp" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $desc — expected '$exp', got '$got'"; fi
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# nongit — plain dir, no repo
_t nongit "not a git repo"

# greenfield — repo, zero commits
git init -q; git config user.email t@t; git config user.name t
_t greenfield "git repo with no commits"

# code_node — has package.json + a commit on default branch
echo '{}' > package.json; git add -A; git commit -qm init
_t code_node "node project on default branch (marker beats clean_default)"

# dirty_default — uncommitted change on default branch, drop the language marker
rm package.json; git commit -qam rm-pkg
echo x > scratch.txt
_t dirty_default "uncommitted change on default branch"

# branch_ahead — feature branch with a commit ahead of default
git checkout -q -b feature/x; git add -A; git commit -qm work
_t branch_ahead "feature branch ahead of base"

# Non-standard default branch (trunk) — no remote; dirty + ahead must still resolve
TRUNK=$(mktemp -d); cd "$TRUNK"
git init -q -b trunk 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/trunk; }
git config user.email t@t; git config user.name t; git config init.defaultBranch trunk
echo hi > a.txt; git add -A; git commit -qm init
echo more > a.txt
_t dirty_default "uncommitted change on non-standard default branch (trunk)"
git checkout -q -b feature/y; git add -A; git commit -qm work
_t branch_ahead "feature branch ahead of trunk base"
rm -rf "$TRUNK"

echo "first-task-detect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
