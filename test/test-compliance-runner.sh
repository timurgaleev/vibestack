#!/usr/bin/env bash
# test-compliance-runner.sh — the rule/skill compliance runner, without tokens.
#
# Covers (test/evals/compliance/compliance.test.ts, fake claude on PATH):
#   - every shipped spec validates; git, claude-code-usage, style, careful and
#     freeze each have one;
#   - supportive / neutral / competing prompts are built from one task, and a
#     skill spec still opens with its slash command;
#   - forbidden, required, judge and order steps grade deterministically;
#   - the table carries raw passed/graded counts per level and errored runs;
#   - the promote-to-hook list names deterministic steps that fail under
#     neutral or competing pressure;
#   - every session gets --setting-sources project,local and a per-call
#     --max-budget-usd, and the runner stops at the USD cap;
#   - a session or judge call that reports no cost is booked at its full
#     allowance, judge calls count against the cap, and a rule spec's source
#     is the session's CLAUDE.md.
#
# The paid runner itself is `bun run test:compliance`; it is never part of CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v bun >/dev/null 2>&1; then
  echo "SKIP: bun not installed"
  exit 0
fi

bun test "$ROOT/test/evals/compliance/"

grep -q '"test:compliance": "bun run test/evals/compliance/run.ts"' "$ROOT/package.json" \
  || { echo "FAIL: package.json lacks the test:compliance script"; exit 1; }

echo "PASS: compliance runner"
