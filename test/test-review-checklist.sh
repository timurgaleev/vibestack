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
#   - Pass 1 carries "Production Failure Modes" (non-idempotent webhooks,
#     lazy env reads, retried writes without a key, fail-open gates, fallbacks
#     consumed as success) with the intentional-empty-contract exemption, and
#     each of its `rg` probes matches a fixture showing the defect;
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

echo "Production Failure Modes"
PF="$(section "$CL" '#### Production Failure Modes')"
P1="$(awk '/^### Pass 1/{on=1;next} on && /^### /{exit} on{print}' "$CL")"
printf '%s\n' "$P1" | grep -qx '#### Production Failure Modes' \
  && ok "section sits in Pass 1" || no "Production Failure Modes not in Pass 1"
grep -q '^- \*\*Pass 1 (CRITICAL):\*\*.*Production Failure Modes' "$CL" \
  && ok "Instructions Pass 1 list names it" || no "Instructions Pass 1 list omits it"
for want in 'idempoten' 'fail fast at startup' 'idempotency key' 'reads as pass' 'intentional empty contract' 'file:line'; do
  printf '%s\n' "$PF" | grep -q "$want" && ok "section has: $want" || no "section missing: $want"
done

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

  # Production Failure Modes probes, each against fixtures holding the defect.
  mkdir -p "$TMP/pf"
  cat > "$TMP/pf/billing.py" <<'PY'
import os
from tenacity import retry, stop_after_attempt

@app.post("/webhooks/stripe")
def stripe_webhook(request):
    event = stripe.Webhook.construct_event(request.body, sig, secret)
    api_key = os.environ["LEDGER_API_KEY"]
    db.execute("UPDATE orders SET status = 'paid' WHERE id = %s", (event.order_id,))

@retry(stop=stop_after_attempt(3))
def create_charge(amount):
    return payments.charges.create(amount=amount)

def load_settings():
    try:
        return read_settings()
    except Exception:
        return {}
PY
  cat > "$TMP/pf/items.ts" <<'TS'
export async function listItems() {
  const items = await fetchItems().catch(() => []);
  return { ok: true, items };
}
TS
  cat > "$TMP/pf/gate.sh" <<'SH'
#!/usr/bin/env bash
npm run lint || true
SH
  pprobes="$(printf '%s\n' "$PF" | grep -o '`rg [^`]*`' | tr -d '`')"
  m=0
  while IFS= read -r probe; do
    [ -n "$probe" ] || continue
    m=$((m+1))
    out="$(cd "$TMP/pf" && eval "$probe ." </dev/null 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
      ok "probe matches fixture: ${probe:0:60}"
    else
      no "probe rc=$rc on fixture: $probe ($out)"
    fi
  done <<< "$pprobes"
  [ "$m" -ge 5 ] && ok "found $m production probes" || no "expected at least 5 production probes, found $m"
fi

echo "review/ship shared snippets"
RV="$SRC/skills/review/SKILL.md"
# step FILE "## Step N:" -> body up to the next "## " heading
step() { awk -v h="$2" 'index($0, h) == 1 { on = 1; next } on && /^## / { exit } on { print }' "$1"; }
for s in review ship; do
  "$SRC/bin/vibe-render-skill" "$SRC/skills/$s/SKILL.md" "$TMP/$s.md" >/dev/null 2>&1 \
    || no "$s does not render"
done
# contains RENDERED SNIPPET -> the snippet's bytes appear verbatim in the render
contains() { python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[2]).read().rstrip("\n") in open(sys.argv[1]).read() else 1)' "$1" "$2"; }
for s in review ship; do
  for snip in base-branch-detect confidence-calibration; do
    contains "$TMP/$s.md" "$SRC/lib/snippets/$snip.md" && ok "$s renders $snip verbatim" \
      || no "$s does not render $snip verbatim"
  done
  grep -q "symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed" "$TMP/$s.md" \
    && no "$s keeps its own origin/HEAD fallback" || ok "$s has no private base fallback"
  grep -q 'Force its confidence to 4-5' "$TMP/$s.md" \
    && no "$s keeps its own calibration copy" || ok "$s has no private calibration copy"
done
step "$TMP/ship.md" '## Step 7:' > "$TMP/ship-s7"
contains "$TMP/ship-s7" "$SRC/lib/snippets/implementer-dispatch-rules.md" \
  && ok "ship Step 7 child prompt carries the implementer rules" || no "ship Step 7 lacks the implementer rules"
awk '/^### Step 5d:/{on=1;next} on && /^#{1,3} /{exit} on{print}' "$TMP/review.md" > "$TMP/review-5d"
contains "$TMP/review-5d" "$SRC/lib/snippets/test-value-bar.md" \
  && ok "review Step 5d carries the test value bar" || no "review Step 5d lacks the test value bar"

echo "review/ship host paths"
hp="$("$SRC/bin/vibe-lint-sources" "$SRC" 2>&1 | grep -E 'skills/(review|ship)/SKILL\.md:[0-9]+: hard-coded host path' || true)"
[ -z "$hp" ] && ok "no hard-coded host path in review or ship" || no "host-only paths remain: $(printf '%s' "$hp" | sed 's/^warn: //; s/: [^0-9].*//' | tr '\n' ' ')"
# A missing design checklist must stop, not read as "nothing to flag".
DR="$(sed -n '/^## Design Review (conditional/,/^## Step 9.1:/p' "$SHIP")"
printf '%s\n' "$DR" | grep -q 'skipping design review' && no "ship skips design review silently when the checklist is missing" \
  || ok "ship has no silent design-checklist skip"
printf '%s\n' "$DR" | grep -q '\.\./review/design-checklist\.md`.*\*\*STOP\*\*' \
  && ok "ship stops when the design checklist cannot be read" || no "ship design checklist read is not fail-closed"

echo "SCOPE_UNAVAILABLE consumers"
# A failed scope must run every specialist; normal flags keep the subset.
SR="$TMP/scope-repo"; mkdir -p "$SR" "$TMP/vh/bin"
git -C "$SR" init -q && git -C "$SR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git -C "$SR" update-ref refs/remotes/origin/main HEAD
# scope_block FILE -> the bash fence under "### Detect stack and scope"
scope_block() {
  awk '/^### Detect stack and scope/{s=1;next} s && /^```bash$/{on=1;next} on && /^```$/{exit} on{print}' "$1" \
    | sed 's/<base>/main/g'
}
run_scope() { # FILE STUB_OUTPUT STUB_EXIT -> block output, with a stale SCOPE_AUTH/SCOPE_UNAVAILABLE in the env
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\nexit %s\n' "$2" "$3" > "$TMP/vh/bin/vibe-diff-scope"
  chmod +x "$TMP/vh/bin/vibe-diff-scope"
  (cd "$SR" && SCOPE_AUTH=true SCOPE_UNAVAILABLE=true VIBESTACK_HOME="$TMP/vh" bash -c "$(scope_block "$1")" 2>&1)
}
for f in "$RV" "$SHIP"; do
  n=$(basename "$(dirname "$f")")
  out="$(run_scope "$f" "SCOPE_UNAVAILABLE=true" 2)"
  printf '%s\n' "$out" | grep -q 'SCOPE_UNAVAILABLE=true' && ok "$n prints SCOPE_UNAVAILABLE=true on a failed scope" \
    || no "$n hides a failed scope ($(printf '%s' "$out" | head -1))"
  out="$(run_scope "$f" "SCOPE_BACKEND=true SCOPE_FRONTEND=false" 0)"
  printf '%s\n' "$out" | grep -q 'SCOPE_BACKEND=true' && printf '%s\n' "$out" | grep -q 'SCOPE_UNAVAILABLE=false' \
    && ok "$n keeps normal flags and reports scope available" || no "$n mangles normal flags ($(printf '%s' "$out" | head -1))"
  printf '%s\n' "$out" | grep -q 'SCOPE_AUTH=false' && ok "$n drops a stale SCOPE_AUTH from the environment" \
    || no "$n carries a stale SCOPE_AUTH into the selection"
  sel="$(awk '/^### Select specialists/{on=1;next} on && /^### /{exit} on{print}' "$f")"
  printf '%s\n' "$sel" | grep -q 'SCOPE_UNAVAILABLE=true.*every specialist' \
    && ok "$n selection runs every specialist when the scope is unavailable" || no "$n selection has no unavailable-scope branch"
done
DR="$(sed -n '/^## Design Review (conditional/,/^## Step 9.1:/p' "$SHIP")"
printf '%s\n' "$DR" | grep -q 'SCOPE_UNAVAILABLE=true' && ok "ship design review runs on an unavailable scope" \
  || no "ship design review skips on an unavailable scope"

echo "connect-review Step 3"
S3="$(awk '/^## Step 3:/{on=1;next} on && /^## /{exit} on{print}' "$CR")"
printf '%s\n' "$S3" | grep -q '^| Conversation state and memory admission |' \
  && ok "Step 3 has memory admission row" || no "Step 3 missing memory admission row"
printf '%s\n' "$S3" | grep -q 'Model output written back as a fact' \
  && ok "row grades model output admitted as fact" || no "row lacks the finding grade"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
