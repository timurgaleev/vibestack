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

echo "base ref"
# Step 3 merges origin/<base>; a local <base> may be stale or absent, so every
# diff, log and worktree that measures the branch reads the fetched ref. The
# source is scanned, not the render: shared snippets name a generic <base>.
LOCAL_BASE=$(grep -nE '(diff|log)( --[a-z-]+)* <base>\.\.|merge-base <base> |--detach <tmp> <base>' "$SRC")
if [ -n "$LOCAL_BASE" ]; then
  no "branch range against the local <base>: $(printf '%s' "$LOCAL_BASE" | head -3 | cut -c1-120)"
else
  ok "every branch range uses origin/<base>"
fi
grep -q 'git diff origin/<base>\.\.\.HEAD' "$SKILL" && ok "ranges read origin/<base>" || no "no origin/<base> range found"

sec() { awk -v a="$1" -v b="$2" 'index($0,a)==1{on=1} on&&index($0,b)==1&&index($0,a)!=1{exit} on' "$SKILL"; }

echo "Step 10: review bot triage reports its own failure"
S10=$(sec '## Step 10: Address Greptile' '## Step 10b:')
printf '%s' "$S10" | grep -q '"status"' && ok "triage JSON carries a status" || no "triage JSON has no status"
printf '%s' "$S10" | grep -qF 'Review bot triage: UNAVAILABLE (' && ok "a failed fetch says UNAVAILABLE" || no "a failed fetch reads as zero comments"
printf '%s' "$S10" | grep -qF 'Review bot triage: none' && ok "zero comments says none" || no "no green-path line for zero comments"
printf '%s' "$S10" | grep -qi 'fixing commit SHA' && no "already-fixed replies still cite a fixing commit SHA" || ok "already-fixed replies cite the current diff"
grep -qF 'Review bot triage:' "$SKILL" && sec '## Step 19: Create PR/MR' '## Step 19.5' | grep -qF 'Review bot triage:' \
  && ok "PR body carries the triage line" || no "PR body has no triage line"

echo "Step 19: PR lookup is honest"
LB="$TMP/lookup.sh"
awk '/\*\*Idempotency check:\*\* Check if a PR\/MR already exists/{s=1} s&&/^```bash$/{on=1;next} on&&/^```$/{exit} on' "$SKILL" > "$LB"
mkdir -p "$TMP/stub"
cat > "$TMP/stub/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] || exit 1
[ -n "${STUB_ERR:-}" ] && { printf '%s\n' "$STUB_ERR" >&2; exit 1; }
echo "PR #7: https://x/pull/7"
SH
chmod +x "$TMP/stub/gh"
look() { ( cd "$TMP" && PATH="$TMP/stub:$PATH" STUB_ERR="$1" bash "$LB" 2>&1 ); }
out=$(look 'no pull requests found for branch "feat/x"'); rc=$?
case "$out" in *NO_PR*) ok "'no pull requests found' -> NO_PR" ;; *) no "no-PR stderr reads as: $out" ;; esac
out=$(look 'HTTP 401: Bad credentials (https://api.github.com/graphql)'); rc=$?
case "$out" in *NO_PR*) no "a failed lookup reads as NO_PR (a duplicate PR would be opened): $out" ;;
  *PR_LOOKUP_FAILED*) [ "$rc" -ne 0 ] && ok "any other gh error -> PR_LOOKUP_FAILED, non-zero" || no "lookup failure exits 0" ;;
  *) no "auth failure reads as: $out" ;; esac
out=$(look ''); case "$out" in "PR #7"*) ok "an open PR still reads as open" ;; *) no "open PR reads as: $out" ;; esac
GB="$TMP/lookup-gl.sh"
awk '/^## Step 19: Create PR\/MR/{s=1} s&&/^\*\*If GitLab:\*\*/{g=1} g&&/^```bash$/{on=1;next} on&&/^```$/{exit} on' "$SKILL" > "$GB"
cat > "$TMP/stub/glab" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "mr view" ] || exit 1
[ -n "${STUB_ERR:-}" ] && { printf '%s\n' "$STUB_ERR" >&2; exit 1; }
echo '{"state":"opened","iid":7,"web_url":"https://x/-/merge_requests/7","sha":"abc"}'
SH
chmod +x "$TMP/stub/glab"
glook() { ( cd "$TMP" && PATH="$TMP/stub:$PATH" STUB_ERR="$1" bash "$GB" 2>&1 ); }
out=$(glook 'no open merge request available for "feat/x"')
case "$out" in *NO_MR*) ok "glab 'no open merge request' -> NO_MR" ;; *) no "glab no-MR stderr reads as: $out" ;; esac
out=$(glook 'ERROR: 401 Unauthorized'); rc=$?
case "$out" in *NO_MR*) no "a failed glab lookup reads as NO_MR (a duplicate MR would be opened): $out" ;;
  *PR_LOOKUP_FAILED*) [ "$rc" -ne 0 ] && ok "any other glab error -> PR_LOOKUP_FAILED, non-zero" || no "glab lookup failure exits 0" ;;
  *) no "glab auth failure reads as: $out" ;; esac
out=$(glook ''); case "$out" in *MR_EXISTS*) ok "an open MR still reads as open" ;; *) no "open MR reads as: $out" ;; esac

echo "Step 11: a pass with no coverage is never a clean record"
PERSIST=$(awk '/^### Persist the review result/{on=1;next} on&&/^### /{exit} on' "$SKILL")
grep -qF 'MISSING_COVERAGE' <<<"$PERSIST" && grep -qF 'Recommendation:' <<<"$PERSIST" \
  && ok "COMPLETED is false for MISSING_COVERAGE or a reply with no closing Recommendation line" \
  || no "the adversarial record can log a MISSING_COVERAGE pass as complete"

echo "Step 19: title and body"
S19=$(sec '## Step 19: Create PR/MR' '## Step 19.5')
printf '%s' "$S19" | grep -qF -- '--title "v$NEW_VERSION' && no "the PR title is still spliced into shell source" || ok "no title spliced into shell source"
printf '%s' "$S19" | grep -qF -- '--title "$(cat "$TITLE_FILE")"' && ok "gh reads the title from a written file" || no "gh title not read from a file"
printf '%s' "$S19" | grep -qF '## Blast radius' && ok "PR body has a Blast radius section" || no "no Blast radius section"
printf '%s' "$S19" | grep -qi "problem in the user's words" && ok "Summary opens with the problem" || no "Summary does not open with the problem"

echo "Step 14: follow-ups are real"
S14=$(sec '## Step 14: TODOS.md' '## Step 14.5')
printf '%s' "$S14" | grep -qi 'never invent' && ok "Step 14 never invents follow-ups" || no "no never-invent rule"
printf '%s' "$S14" | grep -qi 'already in TODOS.md' && ok "Step 14 dedupes" || no "no dedupe rule"
printf '%s' "$S14" | grep -qi 'cannot be written.*PR body\|PR body.*cannot be written' && ok "a failed write carries items in the PR body" || no "a failed TODOS write drops the items"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
