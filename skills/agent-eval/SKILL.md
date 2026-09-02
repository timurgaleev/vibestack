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

- Pick the mode per tag. Direct scoring (1-5 against a written rubric) for "is this answer acceptable". Pairwise comparison (A vs B, which is better, or tie) for "did the new prompt improve on the old one". Pairwise is more reliable for regressions; direct scoring gives a number a gate can threshold.
- The judge model must differ from the generator model. Same-family models share failure modes and rate their own style higher.
- In pairwise mode, randomize which candidate is A and which is B on every item, and record the assignment. Position bias is large enough to flip a verdict.
- Write the rubric as a file: `evals/<unit>/judge/rubric-v1.md`. It states each score level with one concrete example. Include two or three few-shot examples of scored outputs at the top so the judge calibrates on the task rather than on general taste.
- The judge prompt is also a versioned file, `evals/<unit>/judge/prompt-v1.md`, and the results record its version. Changing the judge invalidates comparison with older runs.
- Calibrate against a human. Sample 20 judged items, score them by hand into `evals/<unit>/judge/human-sample.jsonl`, and report agreement. For 1-5 scores report simple agreement (same score) and within-one agreement; for pairwise report Cohen's kappa. Below 0.6 kappa or 70% agreement, the judge is not measuring what the rubric says — rewrite the rubric before trusting the number.

Findings:

- **HIGH** — a judged case with no rubric file, or a judge that is the same model and prompt as the generator. The score is not evidence.
- **MEDIUM** — pairwise mode without recorded position assignment. Results cannot be audited for bias.
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
| Cost per task | (input tokens x input price + output tokens x output price) / 1,000,000, averaged | API usage fields |
| Judge agreement | kappa or simple agreement from the Step 3 human sample | calibration file |

Record the price table used in `evals/<unit>/config.json` so cost numbers are reproducible after a price change. Store it as `"price": {"in_per_mtok": <usd>, "out_per_mtok": <usd>}` — USD per million tokens, the unit vendor price pages publish — and divide by a million wherever the runner turns token counts into dollars.

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
  config.json          # model, temperature, seed, concurrency, cost cap, price table (USD per million tokens)
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

1. Load `config.json`; refuse to start if `cost_cap_usd` is missing.
2. Read `cases.jsonl`; fail on duplicate ids.
3. For each case, call the unit with a fixed seed and temperature from config; cap concurrency with a semaphore (default 4).
4. Track spend after every call from the usage fields; stop the run and write partial results when the cap is hit.
5. Apply deterministic scorers, then the judge for cases whose `expected` carries a `rubric` key. A case with neither a deterministic check nor a rubric is an error, not a pass — stop and name the case. A judged case passes only when its judge score reaches the case's threshold (`judge_threshold`, default 4).
6. Append one line per case to `runs/results-<timestamp>.jsonl`: `id`, `tags`, `output`, `passed`, `checks`, `judge_score`, `judge_version`, `judge_position`, `latency_ms`, `tokens_in`, `tokens_out`, `cost_usd`. `judge_position` is the Step 3 randomized assignment — `"A"` or `"B"` in pairwise mode, `null` under direct scoring.
7. Write `summary-<timestamp>.md` with the Step 4 table, overall and per tag.

A Python skeleton the user can start from; keep the same shape in TypeScript:

```python
#!/usr/bin/env python3
import json, time, sys, asyncio
from pathlib import Path

ROOT = Path(__file__).parent
CFG = json.loads((ROOT / "config.json").read_text())
assert "cost_cap_usd" in CFG, "config.json needs cost_cap_usd"

def load_cases():
    cases = [json.loads(l) for l in (ROOT / "cases.jsonl").read_text().splitlines() if l.strip()]
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    return cases

async def run_case(case, sem, spent):
    async with sem:
        if spent[0] >= CFG["cost_cap_usd"]:
            return {"id": case["id"], "skipped": "cost cap"}
        t0 = time.monotonic()
        out, usage = await call_unit(case["input"], seed=CFG["seed"], temperature=CFG["temperature"])
        cost = (usage["in"] * CFG["price"]["in_per_mtok"]
                + usage["out"] * CFG["price"]["out_per_mtok"]) / 1_000_000
        spent[0] += cost
        latency_ms = int((time.monotonic() - t0) * 1000)
        checks = run_scorers(case, out)
        expected = case.get("expected")
        judged = isinstance(expected, dict) and "rubric" in expected
        judge_score, judge_version, judge_position = (
            await run_judge(case, out) if judged else (None, None, None))
        if not checks and not judged:
            raise ValueError(f"{case['id']}: no deterministic check and no rubric — case is unscored")
        threshold = case.get("judge_threshold", 4)
        passed = all(checks.values()) and (not judged or judge_score >= threshold)
        return {"id": case["id"], "tags": case["tags"], "output": out, "checks": checks,
                "passed": passed, "judge_score": judge_score, "judge_version": judge_version,
                "judge_position": judge_position, "latency_ms": latency_ms,
                "tokens_in": usage["in"], "tokens_out": usage["out"], "cost_usd": round(cost, 6)}

async def main():
    sem = asyncio.Semaphore(CFG.get("concurrency", 4))
    spent = [0.0]
    results = await asyncio.gather(*(run_case(c, sem, spent) for c in load_cases()))
    stamp = time.strftime("%Y%m%dT%H%M%S")
    (ROOT / "runs").mkdir(exist_ok=True)
    with open(ROOT / "runs" / f"results-{stamp}.jsonl", "w") as f:
        for r in results:
            f.write(json.dumps(r) + "\n")
    write_summary(results, ROOT / "runs" / f"summary-{stamp}.md")

asyncio.run(main())
```

`call_unit`, `run_scorers`, `run_judge`, and `write_summary` are the four functions to fill in against the real project. `run_judge` returns `(score, judge_version, judge_position)`: the score on the rubric's scale, the version from the `judge/prompt-v1.md` filename, and the Step 3 position assignment — `"A"` or `"B"` in pairwise mode, `None` under direct scoring. Do a dry run with `concurrency: 1` and a cost cap of a few cents before the first full run.

Findings:

- **HIGH** — the runner calls the live unit with real side effects (Step 1 seam missing). Do not run it.
- **MEDIUM** — no seed or temperature in config. Two runs of the same prompt will differ and the gate will flap.

---

## Step 6: Add the regression gate

Commit `evals/<unit>/baseline.json` from a run the user has looked at and accepted, and copy that run's `summary-<timestamp>.md` to `evals/<unit>/baseline-summary.md` in the same commit. `runs/` is gitignored by the `.gitignore` written in Step 5, so a bare filename there is not something a later reviewer can open — the committed summary is the provenance.

```json
{"run_stamp":"20260901T101500","summary":"baseline-summary.md","judge_version":"v1","success_rate":0.87,"cost_per_task_usd":0.0042,"per_tag":{"golden":0.95,"adversarial":0.70}}
```

The gate compares a fresh run to the baseline and fails on either:

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
Judge:       <model> (differs from generator), rubric-v1, mode <direct|pairwise>

Task set:    <N> cases — golden <n>, mined <n>, adversarial <n>
Tags:        <tag list with counts>

Scoring:     deterministic: <exact|regex|schema|trace|grounding>
             judged: <n> cases, threshold >= 4/5
             human sample: 20 items, agreement <pending|kappa 0.xx>

Metrics:     success rate, tool-call correctness, hallucination rate,
             refusal rate, latency p50/p95, cost per task — per tag
Gate:        fail on success drop > N pts, cost increase > M %
Cost cap:    $<x> per local run, $<y> per CI run


RESULTS — <run file>
====================

Metric                  Overall   golden   mined   adversarial   vs baseline
--------------------    -------   ------   -----   -----------   -----------
Success rate            0.87      0.95     0.85    0.70          -0.02
Tool-call correctness   0.91      0.97     0.90    0.80          +0.01
Hallucination rate      0.04      0.00     0.06    0.10          +0.01
Refusal rate            0.03      0.00     0.02    0.20          0.00
Latency p50 / p95 ms    1840/4200                                +5% / +12%
Cost per task           $0.0042                                  +3%
Judge agreement         kappa 0.71 (20 items)

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

1. **Never call a paid API without a run cap.** Every run, local or CI, has `cost_cap_usd` in config and the runner stops when it is reached. A missing cap is a refusal to run, not a warning.
2. **Judge prompts and rubrics are versioned files.** Never an inline string. Every result line records the judge version it was scored with.
3. **Never score with the generator.** The judge is a different model from the one that produced the output, and it never sees the generator's system prompt as its own instructions.
4. **Expected outputs are written before the run.** Copying a live output into `expected` is a snapshot, not an eval. Say so if the user asks for it, then do it only for cases they have read.
5. **Deterministic before judged.** If a program can check it, a program checks it. The judge covers only what remains.
6. **Read-only toward everything outside `evals/`.** This skill creates and edits files under `evals/<unit>/` and the CI config it names. It does not change the prompt, the agent, or the model config; it never modifies cloud resources, purchases anything, or writes to a customer account. Proposed changes to the unit under test go in the report as findings.
7. **Strip PII from mined cases.** No names, emails, account ids, or free-text that identifies a person lands in `cases.jsonl`.
8. **Baseline updates are separate commits.** One commit, only `baseline.json` and the `baseline-summary.md` it points at. CI never rewrites it.
9. **Report noise.** If two baseline runs disagree by more than the gate threshold, say the gate cannot hold at that N and propose a wider one or a larger case set.

{{include lib/snippets/capture-learnings.md}}
