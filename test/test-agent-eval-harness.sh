#!/usr/bin/env bash
# test-agent-eval-harness.sh — the /agent-eval runner skeleton keeps its controls
# when it actually runs.
#
# The skill hands the user a Python runner to start from, so the skeleton is
# executed here, not grepped: it is pulled from the rendered skill, the five
# project functions are stubbed, and it runs against fixture cases in a scratch
# directory. No model is called.
#   - holdout: a development run never calls the unit on a `holdout` case and
#     leaves no holdout record; a `--holdout` run does call it and appends the
#     run stamp and ids to holdout-runs.jsonl;
#   - decoys: a `decoy` case is scored on its canned wrong output without calling
#     the unit; the pass rate is printed; a scorer that passes any decoy fails
#     the run;
#   - reasoning floor: `"reasoning": true` with max_tokens_out under 8192 is a
#     refusal to start;
#   - projection: the block that turns the capped dry run into a cost band for
#     the full run prints the band, flags a band over the cap, and is N-A on an
#     empty dry run.
#
# Usage: test-agent-eval-harness.sh [repo-root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SKILL="$TMP/agent-eval.md"
if ! "$ROOT/bin/vibe-render-skill" "$ROOT/skills/agent-eval/SKILL.md" "$SKILL" >/dev/null 2>&1; then
  no "agent-eval does not render"
  echo; echo "passed: $pass  failed: $fail"; exit 1
fi

# The runner skeleton is the python block that starts with a shebang.
awk '/^```python$/ {on=1; buf=""; next}
     on && /^```$/ {on=0; if (buf ~ /^#!\/usr\/bin\/env python3/) {printf "%s", buf; exit}; next}
     on {buf = buf $0 "\n"}' "$SKILL" > "$TMP/skeleton.py"
if ! grep -q '^asyncio.run(main())$' "$TMP/skeleton.py"; then
  no "runner skeleton not found in the rendered skill"
  echo; echo "passed: $pass  failed: $fail"; exit 1
fi
ok "runner skeleton extracted"

# The five project functions, stubbed: the unit echoes input.answer and logs
# every call; the scorer is exact-match, or accepts anything when lenient.
cat > "$TMP/stubs.py" <<'PY'
import os

async def call_unit(inp, seed, temperature, max_tokens_out, retry_prompt=None):
    with open(os.environ["CALL_LOG"], "a") as f:
        f.write(json.dumps({"inp": inp, "retry": retry_prompt}, sort_keys=True) + "\n")
    flag = os.environ.get("STUB_EMPTY_ONCE")
    if flag and retry_prompt is None and not os.path.exists(flag):
        open(flag, "w").close()
        return "", {"in": 10, "out": max_tokens_out}
    return inp.get("answer", ""), {"in": 10, "out": 5}

def count_tokens(text):
    return len(json.dumps(text))

def run_scorers(case, out):
    if os.environ.get("STUB_SCORER") == "lenient":
        return {"anything": True}
    return {"exact": out == case["expected"]}

async def run_judge(case, out, max_tokens_in, max_tokens_out):
    raise AssertionError("no judged cases in this fixture")

def write_summary(results, path, incomplete=None, spent_usd=0.0, **extra):
    path.write_text((incomplete or "complete") + "\n" + "head=%s\n" % extra.get("head"))
PY

# runner <dir> <config-json> — a scratch eval dir with the fixture cases.
runner() {
  local d="$1"; mkdir -p "$d"
  sed '$d' "$TMP/skeleton.py" > "$d/run.py"
  cat "$TMP/stubs.py" >> "$d/run.py"
  printf 'asyncio.run(main())\n' >> "$d/run.py"
  printf '%s\n' "$2" > "$d/config.json"
  cat > "$d/cases.jsonl" <<'JSONL'
{"id":"gold-1","input":{"answer":"A1"},"expected":"A1","tags":["golden"]}
{"id":"mined-1","input":{"answer":"B1"},"expected":"B1","tags":["mined"]}
{"id":"hold-1","input":{"answer":"H1"},"expected":"H1","tags":["holdout"]}
{"id":"decoy-1","input":{"answer":"D1"},"expected":"D1","decoy_output":"not D1","tags":["decoy"]}
{"id":"decoy-2","input":{"answer":"D2"},"expected":"D2","decoy_output":"","tags":["decoy"]}
{"id":"decoy-3","input":{"answer":"D3"},"expected":"D3","decoy_output":"D3 maybe","tags":["decoy"]}
JSONL
}

CFG='{"cost_cap_usd":1.0,"max_tokens_in":4000,"max_tokens_out":512,"seed":7,"temperature":0,"concurrency":1,
"price":{"in_per_mtok":3,"out_per_mtok":15},"judge_price":{"in_per_mtok":1,"out_per_mtok":5}}'

echo "development run"
D="$TMP/dev"; runner "$D" "$CFG"
out="$(cd "$D" && CALL_LOG="$D/calls.log" python3 -I run.py 2>"$D/err")"; rc=$?
[ "$rc" -eq 0 ] && ok "development run exits 0" || no "development run exit $rc: $(cat "$D/err")"
grep -q '"H1"' "$D/calls.log" 2>/dev/null && no "holdout case was sent to the unit in a development run" \
  || ok "holdout case never reaches the unit in a development run"
[ -e "$D/holdout-runs.jsonl" ] && no "development run wrote a holdout record" || ok "no holdout record from a development run"
grep -qE '"D[123]"' "$D/calls.log" 2>/dev/null && no "decoy case was sent to the unit" \
  || ok "decoy cases are scored without calling the unit"
grep -q '"A1"' "$D/calls.log" 2>/dev/null && ok "golden case still runs" || no "golden case did not run"
printf '%s\n' "$out" | grep -q '^DECOYS: 0/3 passed' && ok "decoy pass rate printed (0/3 under a working scorer)" \
  || no "decoy pass rate missing: $out"

echo "holdout run"
D="$TMP/hold"; runner "$D" "$CFG"
(cd "$D" && CALL_LOG="$D/calls.log" python3 -I run.py --holdout >/dev/null 2>"$D/err"); rc=$?
[ "$rc" -eq 0 ] && ok "--holdout run exits 0" || no "--holdout run exit $rc: $(cat "$D/err")"
grep -q '"H1"' "$D/calls.log" 2>/dev/null && ok "--holdout run calls the unit on the holdout case" || no "holdout case not run under --holdout"
if [ -s "$D/holdout-runs.jsonl" ] && python3 -I -c '
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sys.exit(0 if len(recs) == 1 and recs[0].get("ids") == ["hold-1"] and recs[0].get("run_stamp") else 1)' "$D/holdout-runs.jsonl"; then
  ok "holdout-runs.jsonl records the run stamp and the holdout ids touched"
else
  no "holdout run left no usable record: $(cat "$D/holdout-runs.jsonl" 2>/dev/null)"
fi

echo "lenient scorer"
D="$TMP/lenient"; runner "$D" "$CFG"
out="$(cd "$D" && CALL_LOG="$D/calls.log" STUB_SCORER=lenient python3 -I run.py 2>"$D/err")"; rc=$?
[ "$rc" -ne 0 ] && ok "a scorer that passes a decoy fails the run" || no "lenient scorer passed the run (exit 0)"
printf '%s\n' "$out" | grep -q '^DECOYS: 3/3 passed' && ok "decoy pass rate reports 3/3" || no "decoy rate wrong: $out"
grep -q 'decoy-1' "$D/err" && ok "the passing decoy ids are named" || no "passing decoys not named: $(cat "$D/err")"

echo "reasoning floor"
D="$TMP/reason-low"
runner "$D" "$(printf '%s' "$CFG" | sed 's/"max_tokens_out":512/"max_tokens_out":4096,"reasoning":true/')"
(cd "$D" && CALL_LOG="$D/calls.log" python3 -I run.py >/dev/null 2>"$D/err"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$D/calls.log" ] && grep -q 8192 "$D/err"; then
  ok "reasoning model with max_tokens_out 4096 refuses to start, naming 8192"
else
  no "reasoning floor not enforced (exit $rc): $(tail -2 "$D/err")"
fi
D="$TMP/reason-ok"
runner "$D" "$(printf '%s' "$CFG" | sed 's/"max_tokens_out":512/"max_tokens_out":8192,"reasoning":true/')"
(cd "$D" && CALL_LOG="$D/calls.log" python3 -I run.py >/dev/null 2>"$D/err"); rc=$?
[ "$rc" -eq 0 ] && ok "reasoning model at 8192 runs" || no "8192 refused (exit $rc): $(tail -2 "$D/err")"

echo "retry, decoys and head"
# Value: protects=the one permitted retry on an empty or cut-off reasoning answer exists in the skeleton; fails_when=the runner scores the empty answer instead; why_new=Step 1 promised a retry the skeleton never made; seam=the stubbed call_unit
D="$TMP/retry"
runner "$D" "$(printf '%s' "$CFG" | sed 's/"max_tokens_out":512/"max_tokens_out":8192,"reasoning":true/')"
mkdir -p "$D/prompts"; printf 'Your answer was empty or cut off. Answer again, briefly.\n' > "$D/prompts/retry-v1.md"
(cd "$D" && CALL_LOG="$D/calls.log" STUB_EMPTY_ONCE="$D/emptied" python3 -I run.py >/dev/null 2>"$D/err"); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Answer again' "$D/calls.log" 2>/dev/null; then
  ok "an empty reasoning answer is retried once with the versioned retry prompt"
else
  no "no retry on an empty reasoning answer (exit $rc): $(tail -2 "$D/err")"
fi
# Value: protects=a run with no decoys cannot pass as a proven scorer; fails_when=DECOYS: 0/0 exits 0; why_new=fixtures above all carry three decoys; seam=none
D="$TMP/nodecoy"; runner "$D" "$CFG"; grep -v '"decoy"' "$D/cases.jsonl" > "$D/c2" && mv "$D/c2" "$D/cases.jsonl"
(cd "$D" && CALL_LOG="$D/calls.log" python3 -I run.py >/dev/null 2>"$D/err"); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'decoy' "$D/err" && ok "a run with no decoy cases fails, naming the missing decoys" \
  || no "zero decoys passed (exit $rc): $(tail -1 "$D/err")"
# Value: protects=a summary names the commit it ran on so /land-and-deploy can tie it to a head; fails_when=the head is not passed to write_summary; why_new=summaries carried no head; seam=none
D="$TMP/headrun"; runner "$D" "$CFG"
printf 'runs/\n' > "$D/.gitignore"
git -C "$D" init -q 2>/dev/null; git -C "$D" add -A; git -C "$D" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm x
(cd "$D" && CALL_LOG="$TMP/head-calls.log" python3 -I run.py >/dev/null 2>"$TMP/head-err")
want="$(git -C "$D" rev-parse HEAD)"
sum="$(ls "$D"/runs/summary-*.md 2>/dev/null | head -1)"
grep -qx "head=$want" "$sum" 2>/dev/null && ok "the summary carries the head commit" || no "summary head: $(cat "$sum" 2>/dev/null | tr '\n' '|')"

echo "dry-run projection"
awk '/^```bash$/ {on=1; buf=""; next}
     on && /^```$/ {on=0; if (buf ~ /PROJECTION/) {printf "%s", buf; exit}; next}
     on {buf = buf $0 "\n"}' "$SKILL" > "$TMP/projection.sh"
if [ ! -s "$TMP/projection.sh" ]; then
  no "no projection block (a bash block printing PROJECTION) in the skill"
else
  P="$TMP/proj"; runner "$P" "$CFG"
  printf '%s\n' '{"id":"gold-1","run":0,"tags":["golden"],"passed":true,"cost_usd":0.01}' \
                '{"id":"mined-1","run":0,"tags":["mined"],"passed":true,"cost_usd":0.03}' > "$P/dry.jsonl"
  : > "$P/empty.jsonl"
  proj() {
    sed -e "s#'<[^>]*dry run[^>]*>'#'$P/$1'#" \
        -e "s#'evals/<unit>/cases.jsonl'#'$P/cases.jsonl'#" \
        -e "s#'evals/<unit>/config.json'#'$P/$2'#" "$TMP/projection.sh" > "$P/run-proj.sh"
    (cd "$P" && bash "$P/run-proj.sh" 2>&1)
  }
  # gold-1 x3 (golden_runs default 3) + mined-1 = 4 runs; holdout and decoys excluded.
  out="$(proj dry.jsonl config.json)"
  printf '%s\n' "$out" | grep -q '4 runs' && ok "projection counts the scheduled runs, holdout and decoys excluded" || no "run count wrong: $out"
  printf '%s\n' "$out" | grep -q '0\.04' && printf '%s\n' "$out" | grep -q '0\.12' \
    && ok "projection prints the low-high band from the dry run" || no "band wrong: $out"
  printf '%s\n' "$out" | grep -qi 'over cap' && no "a band under the cap was flagged: $out" || ok "band under the cap is not flagged"
  printf '%s\n' "$CFG" | sed 's/"cost_cap_usd":1.0/"cost_cap_usd":0.1/' > "$P/lowcap.json"
  out="$(proj dry.jsonl lowcap.json)"
  printf '%s\n' "$out" | grep -qi 'over cap' && ok "a band whose high end passes the cap is flagged" || no "over-cap band not flagged: $out"
  out="$(proj empty.jsonl config.json)"
  printf '%s\n' "$out" | grep -q 'PROJECTION: N-A' && ok "empty dry run -> PROJECTION: N-A" || no "empty dry run projected: $out"
  # Value: protects=an unattended chain can stop on the projection gate; fails_when=N-A or over-cap exits 0; why_new=only the printed lines were checked; seam=none
  proj empty.jsonl config.json >/dev/null; rc=$?
  [ "$rc" -ne 0 ] && ok "PROJECTION: N-A exits non-zero" || no "PROJECTION: N-A exits 0"
  proj dry.jsonl lowcap.json >/dev/null; rc=$?
  [ "$rc" -ne 0 ] && ok "an over-cap projection exits non-zero" || no "over-cap projection exits 0"
  proj dry.jsonl config.json >/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "a projection under the cap exits 0" || no "under-cap projection exit $rc"
fi

echo "skill text"
grep -q 'unattended' "$SKILL" && grep -q 'PROJECTION' "$SKILL" \
  && ok "unattended runs stop at the projection gate" || no "no unattended stop at the projection"
grep -qE 'retry-v[0-9]+\.md' "$SKILL" && ok "the retry prompt is a versioned file" || no "retry prompt file not named"
grep -qiE 'decoy cases\.\*\* at least three' "$SKILL" && grep -q 'fewer than three decoys' "$SKILL" \
  && ok "the task set asks for three or more decoys, and fewer is a finding" || no "decoy minimum not stated"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
