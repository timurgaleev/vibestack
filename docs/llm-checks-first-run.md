# How to run the LLM delivery checks for the first time

Three skills in the pack work on the repo rather than on a cloud account:
`/ai-cost-guard` puts a dollar ceiling on every paid-model call, `/agent-eval` builds
and runs an eval harness so a prompt change can be measured, and `/mcp-review` audits
an MCP server before you publish it or wire it into an agent.

Run in that order the first time. A cap before you spend, a measurement before you
change the prompt, a review before you hand an agent new tools.

This page is the first-run path. What each skill covers is in
[`docs/skills.md`](skills.md); for the AWS-side skills see
[`docs/aws-reviews-first-run.md`](aws-reviews-first-run.md).

---

## Prerequisites

**The pack is installed**, per the [README](../README.md#install-in-30-seconds). None
of the three declares hooks or reads `${CLAUDE_SKILL_DIR}`, and the compatibility
matrix rates all three `full` in Claude Code, Cursor and Kiro — see their rows in
[`docs/agent-skills-compatibility-audit.md`](agent-skills-compatibility-audit.md).
Codex CLI has no runtime data in that matrix, so treat it as untested; there, write
`Use $ai-cost-guard` in an ordinary message, since `/` is reserved for Codex's own
commands. All three list `AskUserQuestion` in `allowed-tools`, which the same audit
classes as a Claude Code tool — `/mcp-review` uses it to ask permission before the
live tool listing.

**A repo that calls a paid model API**, for `/ai-cost-guard` and `/agent-eval`.
Nothing else is required to get a first result out of either.

**Optional, per skill:**

| Skill | Optional dependency | Without it |
|---|---|---|
| `/ai-cost-guard` | `aws` CLI with credentials, for the Bedrock budget and quota lines | Every provider-side line reads `unknown`, and the skill says what to run |
| `/agent-eval` | Nothing. It writes the harness in the project's own language | — |
| `/mcp-review` | `npx` plus `@modelcontextprotocol/inspector`, for the optional live tool listing | The live check is skipped; the static review is unchanged |

[`docs/external-tools.md`](external-tools.md) states both dependencies in full.

---

## Run `/ai-cost-guard`

Start here. It is the cheapest of the three to run and the one whose absence costs
real money.

1. From the repo root:

   ```
   /ai-cost-guard
   ```

2. It inventories every call site that spends money — Anthropic, OpenAI, Bedrock,
   Google, Replicate, ElevenLabs, Deepgram, fal and the rest — then reads 30 lines
   above each one to record the calling context: loop, retry, webhook or handler,
   cron, agent step, or one-shot. A site whose trigger nobody can name is a finding
   on its own.

3. Each site is then checked against seven controls: max iterations, capped retries
   with backoff, idempotency key, concurrency cap, per-run budget check, circuit
   breaker, timeout. A bound has to be a number the code compares against. A
   `MAX_STEPS` constant that is defined but never compared is not a bound, and a
   `while True` that ends when the model says `end_turn` is not a bound either — the
   model decides when it stops, the code does not.

4. Provider-side caps are checked separately, and `unknown` is an allowed status but
   not a pass.

**It does not edit your code unless you ask.** When you do, it shows each file's diff
first and applies them one file at a time.

**Where the output goes:** printed. There is no report file.

**You know it worked when** the report ends in a verdict:

- `BLOCK` — a HIGH finding with no fix applied
- `FIX BEFORE MERGE` — only MEDIUM findings remain
- `OK` — the cap block is in place, every site routes through it, every call type it
  dispatches has a ceiling and a reconciler, and at least one provider-side cap has a
  number

Above the verdict sit the findings table (`file:line`, pattern, risk, fix), the cap
block with its three numbers, and the provider checklist.

**The cap block is the deliverable.** Three numbers as config —
`MAX_CALLS_PER_RUN`, `MAX_USD_PER_RUN`, `MAX_USD_PER_DAY` — and one helper that every
call site goes through. The helper prices a request's worst case from its own
arguments, holds that amount against both caps *before* dispatching, and settles the
hold afterwards against what the provider reported. Charging after the response
arrives caps nothing: the request that crosses the limit is the one already in
flight.

---

## Run `/agent-eval`

Second. It calls paid APIs, so read the cap section below before the first run.

1. From the repo root:

   ```
   /agent-eval
   ```

2. **Pick one unit.** The skill will make you: an eval that covers "the whole agent"
   measures nothing. One prompt template, one agent loop, one tool router. It records
   the unit's inputs, outputs, side effects, non-determinism and cost before a single
   case is written — and stops if the unit has side effects with no stub or dry-run
   seam, because the harness cannot run it safely yet.

3. **The task set** goes to `evals/<unit>/cases.jsonl`, one JSON object per line with
   `id`, `input`, `expected` and `tags`. Three sources in order: 10 to 30 golden cases
   written by hand, mined cases pulled from real logs with PII stripped, and
   adversarial cases. Expected outputs are written *before* the run — copying a live
   output into `expected` makes a snapshot test, not an eval.

4. **Scoring** is deterministic first. A judge model covers only what no program can
   check, it is never the model that produced the output, and its rubric and prompt
   are versioned files rather than inline strings.

5. **The harness** is written in the project's own language, reusing the project's
   HTTP client, and it refuses to start when `config.json` is missing any of
   `cost_cap_usd`, `max_tokens_in`, `max_tokens_out`, `price` or `judge_price`.

**Every run has a cost cap, and a run that stops early fails.** The runner reserves
each call's worst case against the cap before dispatch — generator and judge on one
ledger — and settles the real usage afterwards. If a reservation does not fit or a
case raises, the summary is headed `INCOMPLETE`, the runner exits non-zero, and that
run can neither pass the gate nor become a baseline.

**Where the output goes:** files in the repo, listed at the end of the report.

```
evals/<unit>/cases.jsonl
evals/<unit>/config.json
evals/<unit>/scorers/
evals/<unit>/judge/rubric-v1.md
evals/<unit>/judge/prompt-v1.md
evals/<unit>/run.py            (or run.ts)
evals/<unit>/.gitignore        one line: runs/
evals/<unit>/baseline.json
evals/<unit>/baseline-summary.md
evals/<unit>/runs/             timestamped results and summaries, gitignored
```

**You know it worked when** you have a plan block naming the unit, the judge and the
task-set counts, then a results table with a column per tag and a `vs baseline`
column, then `Gate: PASS` or `FAIL` with a reason.

**Then wire the gate.** `baseline.json` is committed from a run you have read and
accepted, together with that run's summary as `baseline-summary.md` — `runs/` is
gitignored, so the committed summary is the only provenance a later reviewer can
open. CI fails the gate on a non-zero runner exit or an `INCOMPLETE` summary, on a
success-rate drop greater than 3 points (overall or on any tag with 5 or more cases),
or on a cost-per-task increase greater than 20%. The thresholds live in
`config.json`, not in the CI yaml, so they are reviewed with the code. Updating the
baseline is a separate commit that touches only those two files, and CI never
rewrites it.

---

## Run `/mcp-review`

Third, and the one to run before an MCP server gets your credentials.

1. From the server's repo:

   ```
   /mcp-review
   ```

2. It locates the entry point and the SDK — Python `mcp`/`fastmcp` or the TypeScript
   `@modelcontextprotocol/sdk` — because the SDK decides which registration patterns
   to look for. It records the transport (`stdio` or streamable HTTP, flagging legacy
   SSE), the tool, resource and prompt counts, and whether any auth middleware is
   mounted. If it finds no entry point it asks rather than guessing.

3. It then reads **every** tool registration in full, schema and description string
   included. Sampling three of twenty tools is not a review; if the server is too
   large for one pass it says which tools were covered.

4. Tool design, auth and scope, input validation and error shape, prompt-injection
   surface, and operability follow, in that order.

**The live check is opt-in and it is not a sandbox.** Listing a server's tools means
starting the server, which runs its code with your privileges. The skill runs it under
`env -i` with a scratch `HOME` and a placeholder `.env` so an exported token cannot
reach the child process — that is credential hygiene, and nothing more. The server can
still read what you can read, write where you can write, and open network connections.
Five conditions all have to hold before it runs: you asked for it, the code is trusted
or the run is confined by an OS-level sandbox you set up first, the scratch `.env`
carries placeholders only, the entry command is an absolute path with no
side-effecting startup, and nothing in the command invokes a tool. `tools/list` is the
whole check. If the code's provenance is unclear, the answer is no — the report records
`Live check: skipped: untrusted code`.

**Where the output goes:** printed. Ask for a file and it writes
`docs/mcp-review-<YYYY-MM-DD>.md`.

**You know it worked when** the header block names the SDK, transport, tool counts,
auth and the `Live check:` outcome, followed by a findings table, severity counts, a
verdict — `SAFE TO RUN`, `RUN ONLY OVER STDIO WITH SCOPED CREDENTIALS`, or `DO NOT RUN
UNTIL CRITICAL FIXED` — and a schema diff per tool with a proposed change.

**It never edits the server.** Proposed schema changes go in the report.

---

## Troubleshooting

**`/agent-eval` refuses to start the runner.** `config.json` is missing one of the
five required keys. A missing cap is a refusal to run, not a warning — fill it in
rather than working around it.

**A run finished but the gate still failed.** Check whether the summary is headed
`INCOMPLETE`. A truncated run's rates are not comparable to the baseline, so the gate
fails without reading them.

**`/agent-eval` reports duplicate case ids.** Fix before running: results are keyed
by id and would silently overwrite. Note that the check parses each line as JSON and
takes only the top-level `id` — a `grep` for `"id"` also matches ids nested inside
`expected`, which is why the skill does not use one.

**Two baseline runs disagree by more than the gate threshold.** The gate cannot hold
at that number of cases. Widen the threshold or grow the case set; the skill says so
rather than letting a noisy gate stand.

**`/mcp-review` records `Live check: skipped: server failed to start (exit <n>)`.**
The inspector's exit status is read before its output, so whatever was printed is
diagnostic text and not a tool listing. Most often the server needs real credentials
to boot — in which case the check stays skipped. Real values are never supplied.

**`/ai-cost-guard` leaves the verdict below `OK` with everything fixed.** Look for a
provider checklist line still marked `unknown`, or a call type the helper cannot
price. Both hold the verdict down by design.

---

## Related

- [`docs/skills.md`](skills.md) — what each skill covers, and its triggers
- [`docs/aws-reviews-first-run.md`](aws-reviews-first-run.md) — the account-side
  companions: `/aws-cost`, `/bedrock-guardrails`, `/kb-review`, `/connect-review`
- [`docs/external-tools.md`](external-tools.md) — the `aws` CLI and MCP inspector
  dependencies, stated in full
