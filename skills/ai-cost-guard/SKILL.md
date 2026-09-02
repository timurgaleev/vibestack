---
name: ai-cost-guard
description: |
  Find every code path that can run up a paid-inference bill without a ceiling (loops, retries, fan-out, agent steps, queues) and require a written dollar cap both in code and at the provider. Use before shipping anything that calls an LLM, speech, or image API, or when a bill was larger than expected.
triggers:
  - ai cost guard
  - runaway api cost
  - cap llm spend
  - unbounded llm loop
  - token budget
  - bedrock spend limit
  - prevent surprise ai bill
allowed-tools:
  - AskUserQuestion
  - Bash
  - Read
  - Edit
  - Write
  - Grep
  - Glob
---

## When to invoke

Use when: "ai cost guard", "cap llm spend", "unbounded llm loop", "token budget", "runaway api cost", "bedrock spend limit", "why was the Anthropic/OpenAI bill so high", or before merging a change that adds a call to a paid model API.

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
When the user types `/ai-cost-guard`, run this skill.

---

## Step 1: Inventory paid-API call sites

Every call to a metered model API is a place where money leaves the account. Find all of them before judging any of them.

```bash
grep -rniE \
  'anthropic|@anthropic-ai/sdk|openai|bedrock-runtime|invoke_?model|converse|boto3.*bedrock|google\.generativeai|replicate|elevenlabs|deepgram|fal\.ai|fal_client|@fal-ai|messages\.create|chat\.completions\.create|responses\.create|generate_content|replicate\.run|\.transcribe|\.subscribe' \
  --include='*.py' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' \
  --include='*.go' --include='*.rb' --include='*.java' --include='*.kt' --include='*.rs' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build \
  --exclude-dir=vendor --exclude-dir=.venv . 2>/dev/null
```

The `-i` matters: a class name (`Anthropic()`, `new OpenAI()`) and a boto3 method (`invoke_model`, `converse`) differ in case from the package and API-operation spellings.

The call site you want is the line that makes a request: `messages.create`, `chat.completions.create`, `responses.create`, `invoke_model`, `converse`, `generate_content`, `replicate.run`, `transcribe`, `subscribe`. Where a file surfaces only through its import or its client construction, open that file and locate the request calls inside it — those are the sites, and the import line is how you found them. Drop type definitions and test fixtures that mock the client.

For each remaining site, read 30 lines above it and record the calling context:

- **loop** — inside `for`, `while`, `map`, `forEach`, `asyncio.gather`, `Promise.all`, a recursive function
- **retry** — wrapped by `tenacity`, `backoff`, `p-retry`, a hand-written `while attempts <`, or an SDK `max_retries` setting
- **webhook / handler** — reachable from an HTTP route, a queue consumer, a Lambda handler, a Slack or GitHub event
- **cron / scheduler** — triggered by a schedule, a `setInterval`, a Celery beat, a GitHub Actions cron
- **agent step** — the response feeds the next prompt (tool use loop, planner/executor, "keep going until done")
- **one-shot** — called once per user action with no repetition around it

Use Glob for `**/*.{yml,yaml,toml,json}` and Read any file whose name mentions `schedule`, `cron`, `queue`, `worker`, or `workflow`; a schedule that fires an LLM job is a call site even though no SDK name appears in it.

The output of this step is a list, one line each: `file:line | context | model | who triggers it`. A site whose trigger cannot be named is a finding by itself (`MEDIUM`): nobody knows how often it runs.

---

## Step 2: Check each site for a ceiling

A call site passes only when every applicable control below is present and the bound is a number, not a comment. Check them in this order; stop at the first `HIGH` per site only if the user asked for a quick pass.

| Control | Applies to | What passes | Finding when missing |
|---------|-----------|-------------|----------------------|
| Max iterations | loop, agent step | `for i in range(MAX_STEPS)`, `while steps < MAX_STEPS`, a hard `break` on a counter | `HIGH` — a stuck model or a "not done yet" reply loops until the account is empty |
| Capped retries with backoff | retry | Explicit attempt limit (`stop_after_attempt`, `max_retries=`, `retries: 3`) and increasing delay | `HIGH` if unbounded; `MEDIUM` if bounded but no backoff (429 storms re-bill every attempt on some providers) |
| Idempotency key | retry, queue, webhook | A stable key per unit of work stored before the call, checked before re-running (`if cache.get(key): return`) | `MEDIUM` — a redelivered message or a retried job pays twice for the same answer |
| Concurrency cap | fan-out | `Semaphore(n)`, `p-limit`, worker pool size, a batch size on `gather`/`Promise.all` | `HIGH` when the fan-out width comes from input size (one call per row, per file, per user) |
| Per-run budget check | all | A counter of calls and estimated dollars compared against a limit before every call, raising when exceeded | `HIGH` — without it no other control adds up to a dollar figure |
| Circuit breaker | retry, queue, cron | After N consecutive failures the job stops and alerts instead of retrying into the next tick | `MEDIUM` |
| Timeout | all | `timeout=` on the client or the request; streaming calls have an overall deadline | `LOW` — a hung request holds a worker but rarely bills; `MEDIUM` inside a retry loop |

How to check quickly per language:

```bash
# Python: bounds, retries, budget words near the call sites found in Step 1
grep -nE 'range\(|while |stop_after_attempt|max_retries|Semaphore|timeout=|budget|MAX_' <file>
# TypeScript / JavaScript
grep -nE 'for \(|while \(|maxRetries|p-limit|pLimit|Promise\.all|timeout|budget|MAX_' <file>
```

Then read the code. A `MAX_STEPS` constant that is defined but never compared is not a bound. A `while True` with a `break` on `stop_reason == "end_turn"` is not a bound; the model decides when it ends, the code does not.

Write each miss as a finding: `file:line | pattern | risk | fix`. The fix column names the exact change (`wrap in run_budget.charge() before the call`, `replace while True with for step in range(MAX_STEPS)`), not a category.

---

## Step 3: Provider-side caps

Code caps stop the bug you know about. Provider caps stop the one you do not. Check both layers and record status for each line of the checklist; `unknown` is an allowed status but it is not a pass.

**AWS Bedrock.** Read-only commands; do not create anything.

```bash
# A budget that covers Bedrock, and whether it has an action (stop/deny) or only a notification
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[].{name:BudgetName,limit:BudgetLimit,filters:CostFilters}' --output table 2>/dev/null
aws budgets describe-budget-actions-for-account \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" --output table 2>/dev/null
# CloudWatch alarms on Bedrock invocation or token metrics
aws cloudwatch describe-alarms --query 'MetricAlarms[?Namespace==`AWS/Bedrock`].[AlarmName,MetricName,Threshold]' --output table 2>/dev/null
# Applied quotas for the models in use (tokens per minute, requests per minute)
aws service-quotas list-service-quotas --service-code bedrock --query 'Quotas[?contains(QuotaName, `tokens per minute`)].[QuotaName,Value]' --output table 2>/dev/null
```

- No budget with a Bedrock filter: `HIGH`. A notification-only budget: `MEDIUM` (an email at 3am does not stop the loop). A budget action that removes the invoke policy or an alarm that triggers a kill switch: pass.
- Quotas at the account default with no per-model throttle: `MEDIUM` when the workload can fan out; note it as pass with the number otherwise.
- If the AWS CLI is not configured, mark every line `unknown` and say what to run.

**Anthropic and OpenAI.** Neither exposes spend limits through the SDK; the check is a question to the user with the console path:

- Anthropic: Console, Settings, Limits. Is a monthly spend limit set on the workspace that owns the key in this repo? What number?
- OpenAI: Settings, Organization, Limits. Is a monthly budget with a hard limit set on the project? What number?
- Missing or "not sure": `HIGH`. Set but shared across prod and dev: `MEDIUM`.

**Keys per environment.** Grep config and CI for the key names:

```bash
grep -rnE 'ANTHROPIC_API_KEY|OPENAI_API_KEY|AWS_ACCESS_KEY_ID|REPLICATE_API_TOKEN|ELEVENLABS_API_KEY|DEEPGRAM_API_KEY|FAL_KEY' \
  --include='*.env*' --include='*.yml' --include='*.yaml' --include='*.toml' --include='*.json' \
  --exclude-dir=node_modules --exclude-dir=.git . 2>/dev/null | grep -vE '=[[:space:]]*$' | sed -E 's/=.*/=<redacted>/'
```

One key used from a laptop, CI, and production is `MEDIUM`: a runaway test run bills the production limit and nobody can tell which one spent it. Never print key values; the `sed` above strips them.

---

## Step 4: Token accounting

Spend is invisible until the code reads what the provider returns.

For every site from Step 1 check:

- **Usage read and logged.** The response's usage object (`usage.input_tokens` / `usage.output_tokens` for Anthropic, `usage.prompt_tokens` / `completion_tokens` for OpenAI, `usage.inputTokens` / `outputTokens` in a Bedrock Converse response, `x-amzn-bedrock-*-token-count` headers for InvokeModel) is read and written to a log line or metric with the run id. Missing: `MEDIUM`. `grep -rnE 'usage\.|input_tokens|prompt_tokens|inputTokens|token-count'` should hit near each site.
- **`max_tokens` set on every call.** A call with no output cap pays for whatever the model decides to write. Missing: `MEDIUM`; `HIGH` inside a loop. `grep -rnE 'max_tokens|maxTokens|max_completion_tokens|maxOutputTokens'` and match hits to sites.
- **Prompt caching where the prefix is stable.** A system prompt, tool list, or document over roughly 1k tokens that is identical across calls and not marked cacheable (`cache_control` on Anthropic, `cachePoint` in Bedrock Converse) is money spent on the same bytes every call. Not a safety finding; record it as `LOW` with the estimated saving from the usage numbers.
- **Model pinned by name.** A model chosen from user input or an env var with no allowlist lets a caller upgrade to the most expensive tier. `MEDIUM`.

Where the project already logs usage, run one sample and put real numbers in the report: tokens per call, calls per run, dollars per run at the provider's list price. A finding with a dollar figure gets fixed; one without gets scheduled.

---

## Step 5: Emit the cap block

The project has to carry three numbers as config and one helper that enforces them. Every call site goes through the helper; a direct client call anywhere else is a finding (`HIGH`).

Write the block in the project's language. Python shape:

```python
# ai_budget.py — the only place the model client is called
import os, threading

MAX_CALLS_PER_RUN = int(os.environ["MAX_CALLS_PER_RUN"])   # e.g. 200
MAX_USD_PER_RUN = float(os.environ["MAX_USD_PER_RUN"])     # e.g. 5.00
MAX_USD_PER_DAY = float(os.environ["MAX_USD_PER_DAY"])     # e.g. 50.00

class BudgetExceeded(RuntimeError): ...

class RunBudget:
    def __init__(self, price_in_per_mtok, price_out_per_mtok, day_store):
        self.calls, self.usd = 0, 0.0
        self._lock = threading.Lock()
        self._in, self._out, self._day = price_in_per_mtok, price_out_per_mtok, day_store

    def call(self, fn, **kwargs):
        kwargs.setdefault("max_tokens", 1024)
        with self._lock:
            if self.calls >= MAX_CALLS_PER_RUN or self.usd >= MAX_USD_PER_RUN:
                raise BudgetExceeded(f"run: {self.calls} calls, ${self.usd:.2f}")
            if self._day.spent_today() >= MAX_USD_PER_DAY:
                raise BudgetExceeded("day cap reached")
            self.calls += 1
        resp = fn(timeout=60, **kwargs)
        cost = (resp.usage.input_tokens * self._in + resp.usage.output_tokens * self._out) / 1e6
        with self._lock:
            self.usd += cost
        self._day.add(cost)
        return resp
```

TypeScript shape: same three env vars read once with a throw when unset, a `RunBudget` class with `call(fn, params)`, `maxTokens` defaulted, `AbortSignal.timeout(60_000)` passed through, usage priced after the response, day store backed by whatever the project already has (Redis, a table, a file for a CLI).

Rules for the block:

- Missing env var fails at startup, not at the first call. No defaults in code that silently allow unlimited spend.
- Day store is shared across processes; an in-memory day counter in a multi-worker service is not a day cap.
- The helper is the only import of the provider client. Enforce it with a lint rule or a grep in CI: `grep -rn 'from anthropic import\|new Anthropic(' src | grep -v ai_budget` must be empty.
- The numbers go in the report and in `.env.example` with a comment naming who approved them.

If the user asked for fixes, apply the helper and route each Step 1 site through it, showing the diff per file. Otherwise present the diff and stop.

---

## Output

```
AI COST GUARD
=============

Project: <name>   Branch: <branch>   Date: <today>
Call sites: <n> across <files>   Providers: <list>

FINDINGS
file:line                         pattern                      risk    fix
--------------------------------  ---------------------------  ------  ----------------------------------------------
src/agent/loop.py:41              while True, ends on model    HIGH    for step in range(MAX_STEPS); raise on overflow
src/ingest/embed.ts:18            Promise.all over all rows    HIGH    pLimit(8); batch of 100 per run
src/jobs/summarize.py:77          tenacity, no stop condition  HIGH    stop_after_attempt(3), wait_exponential
src/api/chat.ts:52                no max_tokens                MEDIUM  maxTokens: 1024 via RunBudget.call
src/jobs/summarize.py:60          usage not logged             MEDIUM  log usage.input_tokens/output_tokens with run id
config/.env.example               one ANTHROPIC_API_KEY        MEDIUM  separate key per env; prod key only in deploy

CAP BLOCK (<language>)
  MAX_CALLS_PER_RUN = <n>
  MAX_USD_PER_RUN   = <n>
  MAX_USD_PER_DAY   = <n>
  helper: <path>   sites routed through it: <k>/<n>

PROVIDER CHECKLIST
  [ ] AWS Budgets, Bedrock filter, with action     — <pass | missing | notification-only | unknown>
  [ ] CloudWatch alarm on AWS/Bedrock tokens        — <status>
  [ ] Bedrock quotas per model                      — <status, number>
  [ ] Anthropic workspace spend limit               — <status, number>
  [ ] OpenAI project hard limit                     — <status, number>
  [ ] Separate keys per environment                 — <status>

MEASURED (if usage logs exist)
  <tokens/call> x <calls/run> = ~$<n>/run at list price; worst case without caps: $<n>/hour

VERDICT: <BLOCK | FIX BEFORE MERGE | OK> — <one sentence>
```

`BLOCK` when any `HIGH` finding has no fix applied. `FIX BEFORE MERGE` when only `MEDIUM` remain. `OK` only when the cap block is in place, every site routes through it, and at least one provider-side cap has a number.

---

## Important Rules

1. **Read-only against the account.** Describe, list, and query only. Never create a budget, change a quota, rotate a key, or purchase anything. Tell the user the exact console path or CLI command and let them run it.
2. **"Only testing locally" is not an exemption.** A local loop bills the same key as production. The cap block applies to scripts, notebooks, and CI the same as to the service.
3. **A fixed list is not a bound.** `for item in items` with no cap fails when `items` can grow; the bound has to be a number the code compares against, not the size of today's input.
4. **Show the diff before editing.** Do not modify code unless the user asked for fixes. When they did, show each file's diff and apply it file by file.
5. **Numbers, not adjectives.** Every cap in the report is a figure. "Reasonable retry limit" is not a finding or a fix.
6. **Never print secrets.** Redact key values in every grep; report the variable name and where it is used.
7. **Unknown is not pass.** A provider checklist line the user cannot answer stays `unknown` and keeps the verdict from reaching `OK`.
8. **The model does not decide when spending stops.** Any loop whose only exit is a model reply (`end_turn`, "DONE", empty tool call) is `HIGH` until a counter sits beside it.

{{include lib/snippets/capture-learnings.md}}
