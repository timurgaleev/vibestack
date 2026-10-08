#!/usr/bin/env bash
# test-ship-doc-contract.sh — /ship's documentation step drives /document-release
# through its spawned-mode contract.
#
# /document-release in a child agent edits docs and reports JSON; it never
# commits or pushes, and it refuses to run at all unless the dispatch marks the
# child with VIBE_SPAWNED=1. If /ship's Step 14.5 drifts from that contract, the
# doc sync silently stops happening, so the step text is checked here.
#
# Usage: test-ship-doc-contract.sh [SKILL.md]   (default: skills/ship/SKILL.md)
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

STEP="$TMP/step14_5.md"
awk '/^## Step 14\.5:/ {on=1} /^## Step 15:/ {on=0} on' "$SKILL" > "$STEP"
[ -s "$STEP" ] || { echo "Step 14.5 not found in $SRC" >&2; exit 1; }

# The quoted prompt the child receives.
PROMPT="$TMP/prompt.md"
awk '/^\*\*Subagent prompt:\*\*/ {on=1; next} /^\*\*Parent processing:\*\*/ {on=0} on && /^>/' "$STEP" > "$PROMPT"

has() { grep -Eq -- "$1" "$2"; }

echo "dispatch"
has 'run_in_background: false' "$STEP" \
  && ok "dispatch runs in the foreground" || no "run_in_background: false missing"
[ -s "$PROMPT" ] && ok "subagent prompt found" || no "subagent prompt missing"
has 'export VIBE_SPAWNED=1' "$PROMPT" \
  && ok "prompt marks the child with export VIBE_SPAWNED=1" || no "VIBE_SPAWNED=1 instruction missing from the prompt"
if grep -Eiq 'commit|push' "$PROMPT"; then
  no "prompt mentions commit/push to the child: $(grep -Ei 'commit|push' "$PROMPT" | head -1)"
else
  ok "prompt never tells the child to commit or push"
fi
has '"schema_version":1' "$PROMPT" \
  && ok "prompt asks for the schema_version 1 result" || no "prompt does not name the result schema"

echo "sibling skill path"
# Codex reads skills from ~/.agents/skills, and Cursor and Kiro have their own
# roots, so a hard-coded Claude path never resolves there.
if grep -Eq '(~|\$HOME|\$\{HOME\})/\.claude' "$STEP"; then
  no "Step 14.5 hard-codes a Claude install path: $(grep -Eo '(~|\$HOME|\$\{HOME\})/\.claude[^ `]*' "$STEP" | head -1)"
else
  ok "Step 14.5 hard-codes no Claude install path"
fi
has '\$\{CLAUDE_SKILL_DIR\}/\.\./document-release/SKILL\.md' "$STEP" \
  && ok "sibling resolved via \${CLAUDE_SKILL_DIR}/../document-release" || no "sibling not resolved via CLAUDE_SKILL_DIR"
has 'DOC_RELEASE_SKILL_MISSING' "$STEP" \
  && ok "missing sibling skill is detected" || no "no check that the sibling skill is readable"
has 'WARNING: /document-release is not installed' "$STEP" \
  && ok "missing sibling skill warns instead of continuing silently" || no "missing sibling skill has no warning"

echo "parent"
has '`schema_version` is `1`' "$STEP" \
  && ok "parent validates schema_version" || no "schema_version check missing"
has 'git add -- ' "$STEP" \
  && ok "parent stages files by name" || no "named staging (git add -- <path>) missing"
has 'Never `git add -A`' "$STEP" \
  && ok "parent forbids git add -A" || no "git add -A not forbidden"
has 'docs: sync documentation for v' "$STEP" \
  && ok "parent commits the doc sync" || no "doc sync commit message missing"
has 'no valid result' "$STEP" \
  && ok "invalid result is a warning, not a pass" || no "invalid-result path missing"

# The blocked/blockers rule must reach the user through AskUserQuestion.
if awk 'BEGIN{RS=""} /blocked/ && /blockers/ && /AskUserQuestion/ {f=1} END{exit !f}' "$STEP"; then
  ok "blocked/blockers path asks the user"
else
  no "blocked/blockers path does not ask the user"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
