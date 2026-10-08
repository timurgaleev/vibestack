#!/usr/bin/env bash
# test-review-checklist.sh — contracts on skills/review/checklist.md and the
# connect-review Bedrock step.
#
# Covers:
#   - the checklist never tells the reviewer to diff a hardcoded origin/main;
#   - the agent-wrapper failure classes sit in the CRITICAL "LLM Output Trust
#     Boundary" section (prompt-only tool requirement, hidden second LLM pass,
#     memory poisoning) and duplicated context sits under "LLM Prompt Issues";
#   - every `rg` probe in those sections is a valid pattern that matches a
#     fixture showing the defect;
#   - greptile-triage.md and TODOS-format.md diff the detected base and cite
#     /ship steps that exist, and ship Step 14 records both kinds of deferral;
#   - connect-review Step 3 carries the conversation-state / memory admission row.
#
# Usage: test/test-review-checklist.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
CL="$SRC/skills/review/checklist.md"
CR="$SRC/skills/connect-review/SKILL.md"
[ -f "$CL" ] && [ -f "$CR" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# section FILE "#### Heading" -> body up to the next heading of level <= 4
section() {
  awk -v h="$2" '
    $0 == h { on = 1; next }
    on && /^#{1,4} / { exit }
    on { print }
  ' "$1"
}

echo "checklist base branch"
if grep -n 'origin/main' "$CL" | grep -vq 'never a hardcoded'; then
  no "checklist diffs a hardcoded origin/main"
else
  ok "no hardcoded origin/main diff instruction"
fi
grep -q 'detected base branch' "$CL" && ok "names the caller's detected base" || no "detected base not named"

echo "review sub-docs"
GT="$SRC/skills/review/greptile-triage.md"
TF="$SRC/skills/review/TODOS-format.md"
SHIP="$SRC/skills/ship/SKILL.md"
grep -q 'git diff origin/main' "$GT" && no "greptile triage diffs a hardcoded origin/main" || ok "greptile triage uses the detected base"
# Every "/ship (Step N)" a sub-doc cites must be a step ship actually has.
for doc in "$GT" "$TF"; do
  for n in $(grep -o '`/ship` (Step [0-9.]*)' "$doc" | grep -o '[0-9][0-9.]*'); do
    grep -q "^## Step $n:" "$SHIP" && ok "$(basename "$doc") cites ship Step $n, which exists" \
      || no "$(basename "$doc") cites ship Step $n, which does not exist"
  done
done
grep -q 'Step 5.5' "$SHIP" && no "ship still cites its old Step 5.5" || ok "ship cites no stale Step 5.5"
sed -n '/^## Step 14:/,/^## Step 15:/p' "$SHIP" | grep -q "Step 2's distribution" \
  && ok "ship Step 14 records a deferred release pipeline" || no "ship Step 14 drops the distribution deferral"

echo "LLM Output Trust Boundary"
TB="$(section "$CL" '#### LLM Output Trust Boundary')"
for want in 'required only by prompt text' 'Hidden second LLM pass' 'Memory poisoning'; do
  printf '%s\n' "$TB" | grep -q "$want" && ok "CRITICAL section has: $want" || no "CRITICAL section missing: $want"
done
PI="$(section "$CL" '#### LLM Prompt Issues')"
printf '%s\n' "$PI" | grep -q 'more than one channel' && ok "prompt issues has duplicated context" \
  || no "prompt issues missing duplicated context"

echo "rg probes"
if ! command -v rg >/dev/null 2>&1; then
  # CI installs ripgrep for this suite, so a missing rg there is a broken job,
  # not a reason to pass without checking the probes.
  if [ -n "${CI:-}" ]; then no "rg not installed (required under CI)"; else echo "  skip rg not installed"; fi
else
  mkdir -p "$TMP/fx"
  cat > "$TMP/fx/agent.py" <<'PY'
SYSTEM_PROMPT = "You must call the lookup tool before answering."
def run(client, history):
    messages = history + [{"role": "system", "content": SYSTEM_PROMPT}]
    reply = client.messages.create(model="m", messages=messages, tool_choice={"type": "auto"})
    if bad(reply):
        reply = repair_prompt_llm(client, reply)  # fallback pass
    memory.add(reply.text)
    return reply
PY
  # Every probe is the backticked `rg ...` text in the two sections.
  probes="$(printf '%s\n%s\n' "$TB" "$PI" | grep -o '`rg [^`]*`' | tr -d '`')"
  n=0
  while IFS= read -r probe; do
    [ -n "$probe" ] || continue
    n=$((n+1))
    # Explicit path and closed stdin: with neither, rg reads stdin — here, the
    # probe list itself.
    out="$(cd "$TMP/fx" && eval "$probe ." </dev/null 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
      ok "probe matches fixture: ${probe:0:60}"
    else
      no "probe rc=$rc on fixture: $probe ($out)"
    fi
  done <<< "$probes"
  [ "$n" -ge 5 ] && ok "found $n probes" || no "expected at least 5 probes, found $n"
fi

echo "connect-review Step 3"
S3="$(awk '/^## Step 3:/{on=1;next} on && /^## /{exit} on{print}' "$CR")"
printf '%s\n' "$S3" | grep -q '^| Conversation state and memory admission |' \
  && ok "Step 3 has memory admission row" || no "Step 3 missing memory admission row"
printf '%s\n' "$S3" | grep -q 'Model output written back as a fact' \
  && ok "row grades model output admitted as fact" || no "row lacks the finding grade"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
