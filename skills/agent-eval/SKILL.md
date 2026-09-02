---
name: agent-eval
description: |
  Build an evaluation harness for an LLM agent, prompt template, or tool-using workflow — a task set, deterministic and judge-based scoring, per-tag metrics, and a regression gate — then run it. Use it when a prompt or model change needs to be measured instead of eyeballed, or when a project ships LLM behavior with no eval set at all.
triggers:
  - agent eval
  - evaluate the agent
  - llm as judge
  - build an eval set
  - prompt regression test
  - measure prompt quality
  - eval harness
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
---

## When to invoke

Use when: "evaluate the agent", "build an eval set", "LLM as judge", "prompt regression test", "did the prompt change make it better", "measure prompt quality", "eval harness".

Do not use for web page performance (`/benchmark`) or for choosing between vendors on a single prompt (`/benchmark-models`). This skill builds a repeatable test suite for one unit of LLM behavior in the user's own project.

## Preamble

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.vibestack/bin/vibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## User-invocable
When the user types `/agent-eval`, run this skill. An optional argument names the unit under test (a file path, a function, or a prompt name); without one, find it in Step 1.

---

## Step 1: Identify the unit under test

Pin down exactly one thing to evaluate. An eval that covers "the whole agent" measures nothing.

Find candidates with Grep and Glob:

- Prompt templates: `**/*prompt*`, `**/prompts/**`, string literals containing `You are` or `system:`
- Agent loops: files that call a chat completion API in a loop and dispatch on tool calls
- Tool routers: a function that maps a model's tool-call name to a handler
- Existing evals or fixtures: `**/eval*`, `**/golden*`, `**/fixtures/**`, `*.jsonl`, transcripts under `logs/`

For the chosen unit, write down its interface before writing any case:

| Field | What to record |
|-------|----------------|
| Inputs | user message, conversation history, retrieved context, tool results — and which are fixed vs varied |
| Outputs | free text, structured JSON, a tool-call sequence, a final answer plus a trace |
| Side effects | files written, HTTP calls, database writes — each must be stubbed or sandboxed in the harness |
| Non-determinism | temperature, sampling, tool results that change over time |
| Cost | model, typical tokens in and out, price in USD per million tokens (the unit `config.json` stores) |

Findings at this step:

- **HIGH** — the unit has side effects with no stub or dry-run flag. The harness cannot run it safely until one exists. Stop and say so; propose the smallest seam (an injectable client, an env flag).
- **MEDIUM** — no existing tests, logs, or transcripts. Every case in Step 2 will be hand-written; say so in the plan.
- **LOW** — prompt text is inlined in code rather than a file. Note it; it makes prompt diffs hard to review but does not block the eval.

---

## Step 2: Build the task set

Store cases as JSONL under `evals/<unit>/cases.jsonl`, one object per line:

```json
{"id":"gold-001","input":{"message":"Refund order 4412"},"expected":{"tool_calls":[{"name":"lookup_order","args":{"id":"4412"}}]},"tags":["golden","refund"]}
```

Fields: `id` (stable, never reused), `input` (whatever the unit takes), `expected` (what a correct run produces — a string, a JSON object, a tool-call list, or a rubric note for judged cases), `tags` (a list; every case has at least one).

Three sources, in this order:

1. **Golden cases, written by hand.** 10-30. Cover the main paths the unit exists for. Write the expected output before running the unit, not after — copying a live output into `expected` turns the eval into a snapshot test of whatever the model did today.
2. **Mined cases.** Pull real inputs from logs or transcripts found in Step 1. Strip PII before saving (names, emails, account ids). Tag them `mined`. Only fill `expected` for cases where the correct output is knowable; leave the rest for judge scoring.
3. **Adversarial cases.** Tag `adversarial`. Include at least one of each: ambiguous input with two valid readings, a prompt-injection attempt inside a tool result or pasted document, empty input, input near the context limit, input in a language the prompt does not mention, a request the unit should refuse.

Check the set before moving on:

```bash
CASES="evals/<unit>/cases.jsonl"
wc -l < "$CASES"
grep -c '"golden"' "$CASES"
grep -c '"adversarial"' "$CASES"
python3 -c 'import collections,json,sys
ids=[json.loads(l)["id"] for l in open(sys.argv[1]) if l.strip()]
print("\n".join(sorted(i for i,n in collections.Counter(ids).items() if n>1)))' "$CASES"
```

The duplicate check reads each line as JSON and takes only the top-level `id`. A `grep` for `"id"` matches nested ids too — `expected.tool_calls[].args.id` in the example above — and reports them as duplicate cases.

Findings:

- **HIGH** — duplicate ids. Fix before running; results keyed by id will silently overwrite.
- **MEDIUM** — fewer than 10 golden cases, or no adversarial cases. The success rate will be too noisy to gate on. Say what is missing and add cases before Step 6.
- **LOW** — a tag used by only one case. Per-tag metrics for it are meaningless; merge or add cases.

---

## Step 3: Design the scoring

Deterministic checks first. A judge is the fallback for what no program can check, not the default.

**Deterministic scorers** (put each in `evals/<unit>/scorers/`):

- Exact match, after normalizing whitespace and case where the task allows it
- Regex match for "contains the order id" style checks
- JSON schema validation for structured output — invalid JSON is a fail, not a partial
- Tool-call trace equality: same tool names in the same order with the same arguments; allow an `ignore_args` list per case for arguments that legitimately vary
- Grounding check: every factual claim in the output that matches a pattern (a number, a date, a name) must appear in the provided context; anything else counts toward the hallucination rate in Step 4

**LLM-as-judge**, only for cases where `expected` is a rubric note rather than a value:

- Score directly: 1-5 against a written rubric, with the case's threshold deciding pass or fail. The runner produces one output per case, so there is nothing for the judge to compare against. "Did the new prompt improve on the old one" is answered by comparing this run's rates to the committed baseline in Step 6, not by asking the judge to rank two candidates.
- The judge model must differ from the generator model. Same-family models share failure modes and rate their own style higher.
- Write the rubric as a file: `evals/<unit>/judge/rubric-v1.md`. It states each score level with one concrete example. Include two or three few-shot examples of scored outputs at the top so the judge calibrates on the task rather than on general taste.
- The judge prompt is also a versioned file, `evals/<unit>/judge/prompt-v1.md`, and the results record its version. Changing the judge invalidates comparison with older runs.
- Calibrate against a human. Sample 20 judged items, score them by hand into `evals/<unit>/judge/human-sample.jsonl`, and report exact agreement (same score) and within-one agreement. Below 60% exact or 90% within-one, the judge is not measuring what the rubric says — rewrite the rubric before trusting the number.

Findings:

- **HIGH** — a judged case with no rubric file, or a judge that is the same model and prompt as the generator. The score is not evidence.
- **MEDIUM** — a rubric with no few-shot examples, or a human sample under 20 items. The agreement number is too noisy to act on.
- **LOW** — a deterministic check that could replace a judged case (for example, the rubric only asks whether the JSON has a field). Convert it.

---

## Step 4: Define the metrics

Compute every metric overall and per tag. Per-tag is where regressions hide: an overall rate that holds steady while `adversarial` drops from 80% to 40% is a regression.

| Metric | Definition | Source |
|--------|------------|--------|
| Task success rate | cases where all deterministic checks pass, or judge score >= the case's threshold (default 4 of 5) | scorers |
| Tool-call correctness | share of cases whose tool-call trace matched expected | trace scorer |
| Hallucination rate | share of outputs with at least one claim not backed by the provided context | grounding scorer |
| Refusal rate | share of outputs that decline; report separately for cases tagged `should-refuse` and everything else | regex on refusal phrasing, or judge |
| Latency p50 / p95 | wall-clock per case, from call to final output | runner |
| Cost per task | generator plus judge for that case: (input tokens x input price + output tokens x output price) / 1,000,000 at each model's own price, averaged | API usage fields |
| Judge agreement | exact and within-one agreement from the Step 3 human sample | calibration file |

Record both price tables used in `evals/<unit>/config.json` so cost numbers are reproducible after a price change: `"price"` for the generator and `"judge_price"` for the judge, each `{"in_per_mtok": <usd>, "out_per_mtok": <usd>}` — USD per million tokens, the unit vendor price pages publish — and divide by a million wherever the runner turns token counts into dollars. The judge is a paid call like any other: its tokens go on the same ledger as the generator's, so a judge-heavy run cannot slip past the cap or under-report cost.

Findings:

- **HIGH** — a refusal rate above zero on `golden` cases, or below 100% on `should-refuse` cases. Either is a correctness bug, not a tuning detail.
- **MEDIUM** — p95 latency more than 3x p50. Usually a retry loop or a tool timeout; worth a look before gating.

---

## Step 5: Write the harness

Use the project's own language. Python if the project is Python, TypeScript if it is TypeScript. No new runtime for the eval alone. Reuse the project's HTTP client and API wrapper so the harness exercises the real call path.

Layout:

```
evals/<unit>/
  cases.jsonl          # Step 2
  config.json          # models, temperature, seed, concurrency, cost cap, per-call token ceilings,
                       #   generator and judge price tables (USD per million tokens)
  scorers/             # Step 3 deterministic checks
  judge/               # rubric-v1.md, prompt-v1.md, human-sample.jsonl
  baseline.json        # Step 6, committed
  baseline-summary.md  # the accepted run's summary, committed next to baseline.json
  runs/                # results-<timestamp>.jsonl + summary-<timestamp>.md, gitignored
  run.py | run.ts      # the runner
  .gitignore           # one line: runs/
```

Write `evals/<unit>/.gitignore` containing the single line `runs/` while scaffolding the directory, before the first run. Without it the timestamped results and summaries land in git on the first run, and the committed `baseline-summary.md` of Step 6 stops being the thing that carries provenance.

The runner, in order:

1. Load `config.json`; refuse to start if `cost_cap_usd`, `max_tokens_in`, `max_tokens_out`, `price`, or `judge_price` is missing. The token ceilings are what makes a worst-case call cost knowable in advance.
2. Read `cases.jsonl`; fail on duplicate ids.
3. For each case, call the unit with a fixed seed and temperature from config, and pass `max_tokens_out` as the call's output limit so the API enforces the same ceiling the ledger reserves against. Count the input first and fail the case if it is over `max_tokens_in` rather than dispatching it — the reservation covers both halves of a call, so both halves need a ceiling that holds. Cap concurrency with a semaphore (default 4).
4. Reserve before every paid call — generator and judge alike — and settle after it. The reservation is the worst-case cost of that call: the configured token ceilings at that model's price. Reserving and settling both happen under one lock over a single ledger, so concurrent cases can never each pass a check against the same remaining budget, and no call can start unless its whole worst case fits under the cap. Settling replaces the reservation with the usage the response actually reported, and checks it against the reservation: a call that reports more than its worst case means a ceiling did not reach the API, and the run stops there instead of continuing past the cap.
5. Apply deterministic scorers, then the judge for cases whose `expected` carries a `rubric` key. A case with neither a deterministic check nor a rubric is an error, not a pass — stop and name the case. A judged case passes only when its judge score reaches the case's threshold (`judge_threshold`, default 4).
6. Append one line per case that ran to `runs/results-<timestamp>.jsonl`: `id`, `tags`, `output`, `passed`, `checks`, `judge_score`, `judge_version`, `latency_ms`, `tokens_in`, `tokens_out`, `judge_tokens_in`, `judge_tokens_out`, `cost_usd`. `cost_usd` is the generator and judge cost for that case combined. A case that did not run gets no line — a record without `passed` and `tags` is worse than a missing one, because the Step 6 gate would count it.
7. Write `summary-<timestamp>.md` with the Step 4 table, overall and per tag. If any case did not run — a reservation that did not fit, or a case that raised — head the summary with `INCOMPLETE: <ran>/<total> cases (<reason>)`, print the same line to stderr, and exit non-zero. A truncated run must never be able to satisfy the gate.

A Python skeleton the user can start from; keep the same shape in TypeScript:

```python
#!/usr/bin/env python3
import json, time, sys, asyncio
from pathlib import Path

ROOT = Path(__file__).parent
CFG = json.loads((ROOT / "config.json").read_text())
for key in ("cost_cap_usd", "max_tokens_in", "max_tokens_out", "price", "judge_price"):
    assert key in CFG, f"config.json needs {key}"

def usd(price, tokens_in, tokens_out):
    return (tokens_in * price["in_per_mtok"] + tokens_out * price["out_per_mtok"]) / 1_000_000

WORST_CASE = {role: usd(CFG[key], CFG["max_tokens_in"], CFG["max_tokens_out"])
              for role, key in (("generator", "price"), ("judge", "judge_price"))}

class BudgetExhausted(Exception):
    pass

class CeilingBreached(Exception):
    pass

def check_input(case_id, role, text):
    n = count_tokens(text)
    if n > CFG["max_tokens_in"]:
        raise ValueError(f"{case_id}: {role} input is {n} tokens, over max_tokens_in "
                         f"{CFG['max_tokens_in']}")

class Ledger:
    """One cap covering generator and judge calls alike.

    reserve() claims a call's worst-case cost before it is dispatched;
    settle() swaps that claim for the usage the response reported. Both
    run under the lock, so two cases cannot pass the check against the
    same remaining budget, and no call starts unless its whole worst
    case fits. settle() also refuses a call that came back costing more
    than it reserved, which is the only way the cap can be walked past.
    """
    def __init__(self, cap):
        self.cap, self.committed, self.spent = cap, 0.0, 0.0
        self.lock = asyncio.Lock()

    async def reserve(self, amount):
        async with self.lock:
            if self.committed + amount > self.cap:
                raise BudgetExhausted(f"${amount:.4f} would exceed cap ${self.cap}")
            self.committed += amount

    async def settle(self, reserved, actual):
        async with self.lock:
            self.committed += actual - reserved
            self.spent += actual
        if actual > reserved:
            raise CeilingBreached(
                f"call cost ${actual:.4f} against a ${reserved:.4f} reservation — "
                "the token ceilings did not reach the API")

def load_cases():
    cases = [json.loads(l) for l in (ROOT / "cases.jsonl").read_text().splitlines() if l.strip()]
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    return cases

async def run_case(case, sem, ledger):
    async with sem:
        expected = case.get("expected")
        judged = isinstance(expected, dict) and "rubric" in expected
        check_input(case["id"], "generator", case["input"])
        await ledger.reserve(WORST_CASE["generator"])
        t0 = time.monotonic()
        out, usage = await call_unit(case["input"], seed=CFG["seed"],
                                     temperature=CFG["temperature"],
                                     max_tokens_out=CFG["max_tokens_out"])
        latency_ms = int((time.monotonic() - t0) * 1000)
        cost = usd(CFG["price"], usage["in"], usage["out"])
        await ledger.settle(WORST_CASE["generator"], cost)

        checks = run_scorers(case, out)
        if not checks and not judged:
            raise ValueError(f"{case['id']}: no deterministic check and no rubric — case is unscored")

        judge_score = judge_version = None
        judge_usage = {"in": 0, "out": 0}
        if judged:
            await ledger.reserve(WORST_CASE["judge"])
            judge_score, judge_version, judge_usage = await run_judge(
                case, out, max_tokens_in=CFG["max_tokens_in"],
                max_tokens_out=CFG["max_tokens_out"])
            judge_cost = usd(CFG["judge_price"], judge_usage["in"], judge_usage["out"])
            await ledger.settle(WORST_CASE["judge"], judge_cost)
            cost += judge_cost

        threshold = case.get("judge_threshold", 4)
        passed = all(checks.values()) and (not judged or judge_score >= threshold)
        return {"id": case["id"], "tags": case["tags"], "output": out, "checks": checks,
                "passed": passed, "judge_score": judge_score, "judge_version": judge_version,
                "latency_ms": latency_ms, "tokens_in": usage["in"], "tokens_out": usage["out"],
                "judge_tokens_in": judge_usage["in"], "judge_tokens_out": judge_usage["out"],
                "cost_usd": round(cost, 6)}

async def main():
    sem = asyncio.Semaphore(CFG.get("concurrency", 4))
    ledger = Ledger(CFG["cost_cap_usd"])
    cases = load_cases()
    settled = await asyncio.gather(*(run_case(c, sem, ledger) for c in cases),
                                   return_exceptions=True)
    results = [r for r in settled if not isinstance(r, Exception)]
    errors = [r for r in settled if isinstance(r, Exception)]
    stamp = time.strftime("%Y%m%dT%H%M%S")
    (ROOT / "runs").mkdir(exist_ok=True)
    with open(ROOT / "runs" / f"results-{stamp}.jsonl", "w") as f:
        for r in results:
            f.write(json.dumps(r) + "\n")
    if any(isinstance(e, CeilingBreached) for e in errors):
        reason = "token ceiling not enforced"
    elif any(isinstance(e, BudgetExhausted) for e in errors):
        reason = "cost cap reached"
    else:
        reason = "case errors"
    incomplete = f"INCOMPLETE: {len(results)}/{len(cases)} cases ({reason})" if errors else None
    write_summary(results, ROOT / "runs" / f"summary-{stamp}.md",
                  incomplete=incomplete, spent_usd=ledger.spent)
    if errors:
        for e in errors:
            print(f"error: {e!r}", file=sys.stderr)
        print(incomplete, file=sys.stderr)
        sys.exit(1)

asyncio.run(main())
```

`call_unit`, `count_tokens`, `run_scorers`, `run_judge`, and `write_summary` are the five functions to fill in against the real project. `call_unit` must pass `max_tokens_out` through as the API call's output limit; one that accepts the argument and drops it is what lets a run spend past the cap. `count_tokens` returns the provider's own count for a string — the tokenizer the model uses, not a word count, since it is what the input half of the reservation rests on. `run_judge` returns `(score, judge_version, usage)`: the score on the rubric's scale, the version from the `judge/prompt-v1.md` filename, and the judge call's own token counts, which is what puts the judge on the same ledger as the generator. It applies both ceilings to its own call the way `run_case` does for the generator — it is the only place that renders the judge prompt, so it is the only place that can check it. `write_summary` prints the `incomplete` line as the summary's first line when it is set. Do a dry run with `concurrency: 1` and a cost cap of a few cents before the first full run.

Findings:

- **HIGH** — the runner calls the live unit with real side effects (Step 1 seam missing). Do not run it.
- **MEDIUM** — no seed or temperature in config. Two runs of the same prompt will differ and the gate will flap.

---

## Step 6: Add the regression gate

Commit `evals/<unit>/baseline.json` from a run the user has looked at and accepted, and copy that run's `summary-<timestamp>.md` to `evals/<unit>/baseline-summary.md` in the same commit. `runs/` is gitignored by the `.gitignore` written in Step 5, so a bare filename there is not something a later reviewer can open — the committed summary is the provenance.

```json
{"run_stamp":"20260901T101500","summary":"baseline-summary.md","judge_version":"v1","success_rate":0.87,"cost_per_task_usd":0.0042,"per_tag":{"golden":0.95,"adversarial":0.70}}
```

The gate compares a fresh run to the baseline and fails on any of:

- a non-zero runner exit, or a summary headed `INCOMPLETE`. The run did not cover the case set, so its rates are not comparable — the gate fails without reading them, and such a run can never become a baseline.
- success rate drop greater than N points (default 3) overall or on any tag with 5 or more cases
- cost per task increase greater than M% (default 20)

Add it as a CI step that runs on changes to prompt files, the agent loop, model config, or `evals/`. Put the thresholds in `config.json`, not in the CI yaml, so they are reviewed with the code. A gate run needs its own cost cap, lower than a local run.

Updating the baseline is a deliberate act: a separate commit that changes only `baseline.json` and `baseline-summary.md`, reviewed by someone other than the author of the prompt change. Never let CI rewrite the baseline on green.

Findings:

- **HIGH** — no baseline committed, or a CI job that regenerates it automatically. The gate cannot fail.
- **MEDIUM** — thresholds looser than the noise floor. Run the baseline twice with the same config; if the two runs differ by more than N, N is too tight or the seed is not honored.

---

## Output

Present the plan before writing the harness, then the results after the first run.

```
AGENT EVAL PLAN
===============

Unit:        <path or name> — <one line: what it takes, what it returns>
Side effects: <none | stubbed via ... | BLOCKED: ...>
Generator:   <model>, temperature <t>, seed <s>
Judge:       <model> (differs from generator), rubric-v1, direct 1-5

Task set:    <N> cases — golden <n>, mined <n>, adversarial <n>
Tags:        <tag list with counts>

Scoring:     deterministic: <exact|regex|schema|trace|grounding>
             judged: <n> cases, threshold >= 4/5
             human sample: 20 items, agreement <pending|0.xx exact / 0.xx within-1>

Metrics:     success rate, tool-call correctness, hallucination rate,
             refusal rate, latency p50/p95, cost per task — per tag
Gate:        fail on success drop > N pts, cost increase > M %
Cost cap:    $<x> per local run, $<y> per CI run


RESULTS — <run file>
====================

Run:     complete | INCOMPLETE <ran>/<total> cases (<reason>) — exit 1, gate fails
Spend:   $<x> of $<cap> cap (generator + judge)

Metric                  Overall   golden   mined   adversarial   vs baseline
--------------------    -------   ------   -----   -----------   -----------
Success rate            0.87      0.95     0.85    0.70          -0.02
Tool-call correctness   0.91      0.97     0.90    0.80          +0.01
Hallucination rate      0.04      0.00     0.06    0.10          +0.01
Refusal rate            0.03      0.00     0.02    0.20          0.00
Latency p50 / p95 ms    1840/4200                                +5% / +12%
Cost per task           $0.0042                                  +3%
Judge agreement         0.65 exact / 0.95 within-1 (20 items)

Gate: PASS | FAIL (<reason>)

Findings
  [HIGH]   <finding> — <where> — <what to do>
  [MEDIUM] ...

Files created
  evals/<unit>/cases.jsonl
  evals/<unit>/config.json
  evals/<unit>/scorers/...
  evals/<unit>/judge/rubric-v1.md
  evals/<unit>/judge/prompt-v1.md
  evals/<unit>/run.py
  evals/<unit>/.gitignore
  evals/<unit>/baseline.json
  evals/<unit>/baseline-summary.md
  .github/workflows/agent-eval.yml (or the project's CI equivalent)
```

---

## Important Rules

1. **Never call a paid API without a run cap.** Every run, local or CI, has `cost_cap_usd` in config. The runner reserves each call's worst-case cost against that cap before dispatch — generator and judge on one ledger — and settles the actual usage afterwards. The same token ceilings go to the call itself: the input is counted and refused if it is over, the output limit is passed to the API, so the worst case reserved is one the call cannot exceed. A missing cap is a refusal to run, not a warning.
2. **A run that stops early is a failed run.** When a reservation does not fit, or a case raises, keep the lines for the cases that completed, head the summary `INCOMPLETE`, and exit non-zero. Never write a placeholder record for a case that did not run, and never let a partial run pass the gate or become a baseline.
3. **Judge prompts and rubrics are versioned files.** Never an inline string. Every result line records the judge version it was scored with.
4. **Never score with the generator.** The judge is a different model from the one that produced the output, and it never sees the generator's system prompt as its own instructions.
5. **Expected outputs are written before the run.** Copying a live output into `expected` is a snapshot, not an eval. Say so if the user asks for it, then do it only for cases they have read.
6. **Deterministic before judged.** If a program can check it, a program checks it. The judge covers only what remains.
7. **Read-only toward everything outside `evals/`.** This skill creates and edits files under `evals/<unit>/` and the CI config it names. It does not change the prompt, the agent, or the model config; it never modifies cloud resources, purchases anything, or writes to a customer account. Proposed changes to the unit under test go in the report as findings.
8. **Strip PII from mined cases.** No names, emails, account ids, or free-text that identifies a person lands in `cases.jsonl`.
9. **Baseline updates are separate commits.** One commit, only `baseline.json` and the `baseline-summary.md` it points at. CI never rewrites it.
10. **Report noise.** If two baseline runs disagree by more than the gate threshold, say the gate cannot hold at that N and propose a wider one or a larger case set.

{{include lib/snippets/capture-learnings.md}}
