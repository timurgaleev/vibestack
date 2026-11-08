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

echo "review/ship army and adversarial bodies"
# One copy of the specialist dispatch/merge and the adversarial passes: a fix
# landed in one skill's copy left the other reviewing with the old rules.
for s in review ship; do
  for snip in review-army adversarial-review; do
    grep -qx "{{include lib/snippets/$snip.md}}" "$SRC/skills/$s/SKILL.md" \
      && ok "$s includes $snip" || no "$s does not include $snip"
    sed "s/{SKILL_NAME}/$s/g" "$SRC/lib/snippets/$snip.md" > "$TMP/$snip.$s.md"
    contains "$TMP/$s.md" "$TMP/$snip.$s.md" && ok "$s renders $snip verbatim" \
      || no "$s does not render $snip verbatim"
  done
done
grep -qF 'partial results are better than no results' "$TMP/ship.md" \
  && no "ship still treats a failed specialist as partial results" || ok "ship has no partial-results sentence"

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
# The scope block lives in a shared snippet, so read the rendered skills.
for n in review ship; do
  f="$TMP/$n.md"
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

echo "Gate integrity"
GI="$(section "$CL" '#### Gate integrity')"
printf '%s\n' "$P1" | grep -qx '#### Gate integrity' && ok "Gate integrity sits in Pass 1" || no "Gate integrity not a CRITICAL category"
grep -q '^- \*\*Pass 1 (CRITICAL):\*\*.*Gate Integrity' "$CL" && ok "Pass 1 list names Gate Integrity" || no "Pass 1 list omits Gate Integrity"
# Every backticked `grep -E…` probe runs over a diff hunk that holds each weakened gate.
cat > "$TMP/gate.diff" <<'DIFF'
+  it.skip('charges once', () => {
+  @pytest.mark.skip(reason="flaky")
+  t.Skip("later")
+#[ignore]
+  @Disabled
+  // eslint-disable-next-line no-unused-vars
+  // @ts-ignore
+x = 1  # noqa
+    continue-on-error: true
+  allow_failure: true
+git commit -m "wip [skip ci]"
+git push --no-verify
+  timeout: 600000
+  retries: 3
+  threshold: 0.5
-  expect(total).toBe(3)
DIFF
gprobes="$(printf '%s\n' "$GI" | grep -o '`grep -E[^`]*`' | tr -d '`')"
g=0
while IFS= read -r probe; do
  [ -n "$probe" ] || continue
  g=$((g+1))
  out="$(eval "$probe" < "$TMP/gate.diff" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ] && ok "gate probe matches: ${probe:0:60}" || no "gate probe rc=$rc: $probe"
done <<< "$gprobes"
[ "$g" -ge 3 ] && ok "found $g gate probes" || no "expected at least 3 gate probes, found $g"
for marker in '@pytest.mark.skip' 't.Skip' '#\[ignore\]' '@Disabled' 'eslint-disable' '@ts-ignore' 'noqa' 'nolint' \
              'continue-on-error' 'allow_failure' 'skip ci' 'no-verify'; do
  printf '%s\n' "$GI" | grep -q -- "$marker" && ok "gate integrity names $marker" || no "gate integrity misses $marker"
done
grep -E '^- Eval threshold changes' "$CL" | grep -q 'code-quality' \
  && ok "eval-threshold suppression covers code-quality comments only" || no "eval-threshold suppression still blanket"
grep -q 'Gate edits:' "$CL" && grep -q 'Gate edits:' "$TMP/review.md" \
  && ok "checklist and review output carry a Gate edits: line" || no "no Gate edits: line"
for opt in 'Restore' 'Keep-justified' 'Keep-other' 'Leave open'; do
  grep -q "$opt" "$TMP/review.md" && ok "review gate disposition: $opt" || no "review gate disposition missing: $opt"
done
grep -q 'Gate integrity' "$SRC/skills/review/specialists/testing.md" && ok "testing specialist has Gate integrity" || no "testing specialist lacks Gate integrity"
sed -n '/^## Step 9:/,/^## Step 10:/p' "$TMP/ship.md" | grep -q 'Gate integrity findings take' && ok "ship Step 9 points at the gate disposition" || no "ship Step 9 has no gate-integrity pointer"

echo "Sideways sweep"
SW="$(awk '/^## Sideways sweep \(every finding\)/{on=1;next} on && /^## /{exit} on{print}' "$CL")"
[ -n "$SW" ] && ok "checklist has the sideways sweep" || no "no sideways sweep section"
for c in 'data loss' 'trust-boundary bypass' 'uncapped spend' 'cache in front of a guarded call' 'dynamic import' 'parity twin' 'transaction'; do
  printf '%s\n' "$SW" | grep -qi "$c" && ok "forced-CRITICAL class: $c" || no "forced-CRITICAL class missing: $c"
done
awk '/^### Step 5.0:/{on=1;next} on && /^#{1,3} /{exit} on{print}' "$TMP/review.md" | grep -qi 'forced-CRITICAL' \
  && ok "Step 5.0 never suppresses a forced-CRITICAL finding" || no "Step 5.0 lacks the forced-CRITICAL exemption"
step "$TMP/review.md" '## Step 4:' | grep -q 'Sideways sweep' && ok "Step 4 points at the sweep" || no "Step 4 has no sweep pointer"

echo "Checklist additions"
for want in 'Not applicable' 'Loosened acceptance' 'preview-first' 'keyboard' 'raises a timing bound' 'strict mode' 'pinned' \
            '#### Repo Conventions & Platform Fit' 'Severity glossary' 'cut fix growth first' 'Zero findings is a valid' \
            'exhaustive over its enum' 'Math.random' 'kind × owner'; do
  grep -qF -- "$want" "$CL" && ok "checklist: $want" || no "checklist missing: $want"
done
SP="$SRC/skills/review/specialists"
grep -q '^### Negative Assertions' "$SP/testing.md" && ok "testing: Negative Assertions" || no "testing: no Negative Assertions"
grep -q 'recomputed the way the code computes it' "$SP/testing.md" && ok "testing: recomputed expectation is a self-comparison" || no "testing: no recomputed-expectation rule"
grep -q 'demonstrated defect' "$SP/maintainability.md" && grep -q 'guard changed' "$SP/maintainability.md" \
  && ok "maintainability: DRY needs a demonstrated defect; guarded strings" || no "maintainability DRY rule not updated"
grep -q 'lines_removable' "$SP/simplification.md" && grep -q 'net: -N lines' "$SP/simplification.md" \
  && grep -qi 'never.*delet.*test' "$SP/simplification.md" && ok "simplification: removable lines, net footer, tests kept" \
  || no "simplification reporting not updated"
[ "$(grep -c '^### ' "$SP/security.md")" -ge 8 ] && grep -q 'Open redirect' "$SP/security.md" \
  && ok "security specialist gained its bullets" || no "security specialist bullets missing"
DC="$SRC/skills/review/design-checklist.md"
ids=$(grep -oE '\[slop-[a-z-]+\]' "$DC" | sort -u | wc -l | tr -d ' ')
[ "$ids" -ge 4 ] && [ "$ids" -le 10 ] && ok "design checklist has $ids rule-id'd slop items (4-10)" || no "design checklist slop ids: $ids, want 4-10"
for id in layout-transition justified-text tiny-text all-caps-body; do
  grep -qF "[slop-$id]" "$DC" && ok "design id slop-$id" || no "design id slop-$id missing"
done

echo "Targeted pass and lead judgment"
[ -f "$SP/targeted.md" ] && grep -qi 'deleted lines' "$SP/targeted.md" && ok "targeted specialist exists" || no "no targeted specialist"
for s in review ship; do
  grep -q 'targeted.md' "$TMP/$s.md" && grep -qi 'regardless of DIFF_LINES' "$TMP/$s.md" \
    && ok "$s dispatches the targeted pass regardless of size" || no "$s does not dispatch the targeted pass"
  grep -q 'Lead judgment' "$TMP/$s.md" && grep -q 'test_stub, cause' "$TMP/$s.md" \
    && ok "$s merge has lead judgment and an optional cause" || no "$s merge lacks lead judgment / cause"
done

echo "Review red proof, validator safety, scope fields, smoke probes"
grep -q 'Regression proof' "$TMP/review.md" && awk '/^### Step 5a:/{on=1;next} on && /^#{1,3} /{exit} on{print}' "$TMP/review.md" | grep -qi 'against the unfixed code' \
  && ok "test-stub fixes are proven red first" || no "test-stub fix has no red proof"
grep -qi 'read-only' "$TMP/review.md" && grep -q 'never in plan mode\|never run it in plan mode' "$TMP/review.md" \
  && ok "validators are inspected before running" || no "no validator safety rule"
grep -q 'Diff read: full|partial' "$TMP/review.md" && grep -q 'Undeclared behavior changes:' "$TMP/review.md" \
  && ok "Scope Check reports diff coverage and undeclared changes" || no "Scope Check fields missing"
step "$TMP/review.md" '## Step 4:' | grep -qi 'strip hostnames' && ok "WebSearch queries are sanitized" || no "no search sanitize rule"
S47="$(step "$TMP/review.md" '## Step 4.7:')"
printf '%s\n' "$S47" | grep -qi 'riskiest' && printf '%s\n' "$S47" | grep -qi 'timeout' && printf '%s\n' "$S47" | grep -q 'test_stub' \
  && printf '%s\n' "$S47" | grep -qi 'pending execution' && ok "Step 4.7 runs bounded smoke probes" || no "no Step 4.7 smoke probes"
grep -q '9.2.1' "$TMP/ship.md" && ok "ship points at the smoke probes" || no "ship has no smoke-probe pointer"
grep -qi 'validator.*read-only\|read-only.*validator' "$TMP/ship.md" && ok "ship Step 8 inspects validators" || no "ship Step 8 runs validators blind"

echo "Greptile fetch and resolution"
GT_FETCH="$TMP/gt-fetch.sh"
awk '/^## Fetch/{s=1} s&&/^```bash$/{on=1;next} on&&/^```$/{exit} on' "$GT" > "$GT_FETCH"
for want in -- '--paginate' 'per_page=100' 'in_reply_to_id == null' 'pulls/$PR_NUMBER/reviews'; do
  [ "$want" = "--" ] && continue
  grep -qF -- "$want" "$GT_FETCH" && ok "greptile fetch: $want" || no "greptile fetch missing: $want"
done
mkdir -p "$TMP/gtstub"
cat > "$TMP/gtstub/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "o/r"; exit 0 ;;
  "pr view") echo "7"; exit 0 ;;
esac
[ "$1" = api ] || exit 1
[ -n "${GT_FAIL:-}" ] && { echo "HTTP 403: rate limit exceeded" >&2; exit 1; }
q=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && q="$a"; prev="$a"; done
case "$*" in *pulls/7/comments*) f="$GT_FX/line.json" ;; *issues/7/comments*) f="$GT_FX/top.json" ;; *reviews*) f="$GT_FX/rev.json" ;; *) exit 1 ;; esac
jq -c "$q" "$f"
SH
chmod +x "$TMP/gtstub/gh"
mkdir -p "$TMP/gtfx"
printf '%s\n' '[{"id":1,"user":{"login":"greptile-apps[bot]"},"position":3,"in_reply_to_id":null,"path":"a.py","line":3,"body":"bug","html_url":"u1"},{"id":2,"user":{"login":"greptile-apps[bot]"},"position":3,"in_reply_to_id":1,"path":"a.py","line":3,"body":"reply","html_url":"u2"}]' > "$TMP/gtfx/line.json"
printf '[]\n' > "$TMP/gtfx/top.json"
printf '%s\n' '[{"id":9,"user":{"login":"greptile-apps[bot]"},"body":"summary","html_url":"u9"}]' > "$TMP/gtfx/rev.json"
gt_run() { ( cd "$TMP" && PATH="$TMP/gtstub:$PATH" GT_FX="$TMP/gtfx" GT_FAIL="${1:-}" bash "$GT_FETCH" 2>&1 ); }
if command -v jq >/dev/null 2>&1; then
  out=$(gt_run); dir=$(printf '%s\n' "$out" | sed -n 's/^GREPTILE_DIR: //p')
  [ -n "$dir" ] && [ "$(grep -c . "$dir/line.json" 2>/dev/null)" = 1 ] && [ "$(grep -c . "$dir/review.json" 2>/dev/null)" = 1 ] \
    && ok "fetch keeps thread roots and review bodies, drops replies" || no "fetch output: $out"
  out=$(gt_run 1)
  case "$out" in *"GREPTILE: error ("*) ok "an API failure is GREPTILE: error, not a skip" ;; *) no "API failure reads as: $out" ;; esac
fi
grep -qi 'fixing commit SHA' "$GT" && no "greptile triage still asks for a fixing commit SHA" || ok "already-fixed cites the current diff"
grep -qF '<commit-sha>' "$GT" && no "reply templates still cite a commit SHA" || ok "reply templates cite file:line in the current diff"
GR="$(awk '/^### Greptile comment resolution/{on=1;next} on && /^#{1,3} /{exit} on{print}' "$TMP/review.md")"
printf '%s\n' "$GR" | grep -q 'A: Fix it now, B: Acknowledge' && no "review gives VALID comments two dispositions" || ok "VALID comments have one disposition"
printf '%s\n' "$GR" | grep -qi 'back through Step 5c' && ok "FP fix-anyway goes back through ASK" || no "FP fix-anyway skips ASK"

echo "Documented standards"
grep -q '^### Documented standards' "$SP/maintainability.md" && grep -q 'CONTRIBUTING' "$SP/maintainability.md" \
  && grep -q '6' "$SP/maintainability.md" && ok "maintainability checks documented standards" || no "no Documented standards section"
step "$TMP/review.md" '## Step 4:' | grep -q 'Documented standards' && ok "review main pass checks standards" || no "review main pass skips standards"

echo "connect-review Step 3"
S3="$(awk '/^## Step 3:/{on=1;next} on && /^## /{exit} on{print}' "$CR")"
printf '%s\n' "$S3" | grep -q '^| Conversation state and memory admission |' \
  && ok "Step 3 has memory admission row" || no "Step 3 missing memory admission row"
printf '%s\n' "$S3" | grep -q 'Model output written back as a fact' \
  && ok "row grades model output admitted as fact" || no "row lacks the finding grade"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
