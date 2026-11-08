#!/usr/bin/env bash
# test-address-pr-review.sh — contracts on how /address-pr-review receives
# review threads and red CI.
#
# Covers:
#   - every open thread is read before the first edit, and genuinely ambiguous
#     ones go to the user as one batched question;
#   - a "fix" checks whether the current code was deliberate (git log -L /
#     blame), and "implement X properly" checks X's callers first;
#   - a suspected flake is rerun once; a second failure is real, infra reds are
#     never flakes, loosening a gate needs approval, both run ids are reported;
#   - replies state the change with no filler; a fix that adds a test carries
#     red proof.
#
# Usage: test/test-address-pr-review.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
SK="$SRC/skills/address-pr-review/SKILL.md"
[ -f "$SK" ] || { echo "not a repo root: $SRC" >&2; exit 2; }

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

S3="$(awk '/^## Step 3:/{on=1;next} on && /^## /{exit} on{print}' "$SK")"
S6="$(awk '/^## Step 6:/{on=1;next} on && /^## /{exit} on{print}' "$SK")"
OUT="$(awk '/^## Output/{on=1;next} on && /^## /{exit} on{print}' "$SK")"

echo "reading threads"
printf '%s\n' "$S3" | grep -qi 'every open thread before' && ok "all threads read before any edit" || no "threads edited one at a time before all are read"
printf '%s\n' "$S3" | grep -qi 'one question' && ok "ambiguous threads batched into one question" || no "ambiguity not batched"
printf '%s\n' "$S3" | grep -q 'git log -L' && ok "a fix checks whether the code was deliberate" || no "no git log -L / blame check"
printf '%s\n' "$S3" | grep -qi 'callers' && printf '%s\n' "$S3" | grep -qi 'propose removing' \
  && ok "'implement X properly' checks callers first" || no "no caller check before implementing"
printf '%s\n' "$S3" | grep -qi 'red proof' && ok "a fix that adds a test carries red proof" || no "no red proof for added tests"

echo "red CI"
printf '%s\n' "$S3" | grep -qF 'gh run rerun <run-id> --failed' && ok "a suspected flake is rerun with --failed" || no "no rerun command"
printf '%s\n' "$S3" | grep -qi 'second failure is real' && ok "a second failure is real" || no "a repeat failure can still be called a flake"
printf '%s\n' "$S3" | grep -qi 'never.*flake' && ok "harness/infra reds are never flakes" || no "infra reds can be called flakes"
printf '%s\n' "$S3" | grep -qi 'explicit approval' && ok "loosening a gate needs explicit approval" || no "gate loosening needs no approval"
printf '%s\n' "$OUT" | grep -q 'run ids\|→ <run' && ok "report carries both run ids" || no "report drops the run ids"

echo "replies"
printf '%s\n' "$S6" | grep -qi 'no thanks' && ok "replies carry no filler" || no "replies may carry thanks/agreement filler"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
