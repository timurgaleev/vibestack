---
name: investigate
description: |
  Root-cause debugging for errors, stack traces, or something that stopped working; no fix without a root cause.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
  - WebSearch
triggers:
  - debug this
  - fix this bug
  - why is this broken
  - root cause analysis
  - investigate this error
  - test fails
  - failing test
  - build is broken
  - stack trace
hooks:
  PreToolUse:
    - matcher: "Edit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/investigate}/../freeze/bin/check-freeze.sh"
          statusMessage: "Checking debug scope boundary..."
    - matcher: "Write"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/investigate}/../freeze/bin/check-freeze.sh"
          statusMessage: "Checking debug scope boundary..."
    - matcher: "NotebookEdit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/investigate}/../freeze/bin/check-freeze.sh"
          statusMessage: "Checking debug scope boundary..."
---

## When to invoke

Use when asked to "debug this", "fix this bug", "why is this broken", "investigate this error", or "root cause analysis". Proactively invoke this skill (do NOT debug directly) when the user reports errors, 500 errors, stack traces, unexpected behavior, "it was working yesterday", or is troubleshooting why something stopped working.

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## Iron Law

**NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST.**

Fixing symptoms creates whack-a-mole debugging. Every fix that doesn't address root cause makes the next bug harder to find. Find the root cause, then fix it.

---



## Phase 1: Root Cause Investigation

Gather context before forming any hypothesis.

1. **Collect symptoms:** Read the error messages, stack traces, and reproduction steps. If the user hasn't provided enough context, ask ONE question at a time via AskUserQuestion.

2. **Read the code:** Trace the code path from the symptom back to potential causes. Use Grep to find all references, Read to understand the logic.

3. **Check recent changes:**
   ```bash
   git log --oneline -20 -- <affected-files>
   ```
   Was this working before? What changed? A regression means the root cause is in the diff.

4. **Feedback loop:** Before any hypothesis, build a command that shows the bug on demand. Take the first of these that works:
   1. a failing test in the project's own runner;
   2. `curl` (or the API client) against a locally running service;
   3. a CLI run whose output is checked by a snapshot diff against a known-good capture;
   4. a headless browser script for UI bugs (`/browse`);
   5. trace replay — feed a captured request, event or log line back through the code;
   6. a throwaway harness that calls the failing function directly;
   7. a fuzz loop over the input space, for crashes on some inputs only;
   8. bisection (`git bisect run <loop-command>`) when a known-good revision exists;
   9. differential — the same input through the good and the bad version or environment, outputs diffed.

   Bisection and differential runs drive a loop rather than replace one: the `LOOP:` line names the command they run. Bisect only from a clean tree — stash or revert every probe and tagged log first, so nothing rides across revisions — and run `git bisect reset` as soon as it names the first bad commit, before any other step.

   Tighten it until it is fast, sharp and deterministic: seconds, not minutes; red on the reported symptom, not a nearby failure; the same result every run. For a flaky bug, raise the reproduction rate first — loop the command, pin seeds, clocks and ordering, add load or narrow the timing window — and record the rate (`red 7/50`). A failure that is red only in CI, or too rare to catch locally, is not a stop: its `LOOP:` line is the rate loop in `flake.md` section 1 (path in Phase 2; CI-only: the environment diff there), and its symptom is the CI log. If no way gives a red run, stop and say exactly what you need (a log, a payload, access, a recording, an environment) and ask for it; a `headless` or `spawned` session reports `BLOCKED` with that list. Never work on a bug you cannot see.

   When the loop runs red, print one line: `LOOP: <command> — ran: yes — red on: <symptom>`. No Phase 2 until the `LOOP:` line is printed for a command you actually ran.

5. **Minimise:** Cut input, config and steps until removing anything more turns the loop green. Phase 4's regression test is built from this minimised repro.

6. **Instrument the boundaries:** When the bug crosses components (client → API → queue → worker → store), log the value at every component boundary in one run and read where it first goes wrong, instead of one hop per run. Log a secret only as `SET`/`UNSET`, never its value. Tag every temporary log line `[DEBUG-<short>]` (a short id for this investigation, e.g. `[DEBUG-a3f]`) so Phase 5 can find all of them.

7. **Check investigation history:** Search prior learnings for investigations on the same files. Recurring bugs in the same area are an architectural smell. If prior investigations exist, note patterns and check if the root cause was structural.

{{include lib/snippets/prior-learnings.md}}

**Redact:** repro commands reference secrets through an environment variable (`-H "Authorization: Bearer $API_TOKEN"`), never a literal. Pasted output is signal lines only — the error, the failing assertion, the boundary lines — with any token, password, cookie or key shown as `<REDACTED>`. Before an artifact leaves this session (a repro script, a report file, the learnings JSON), write it with the Write tool and scan it; any non-zero exit means redact and re-scan before using it:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-redact" scan --file "<artifact-path>"; echo "REDACT_EXIT: $?"
```

**When the failing component is an LLM agent**, reproduce first: the same prompt, the same tools and the same memory state. A failure you cannot replay is not yet evidence about any layer. Then triage by layer, each with its evidence question:

- **System prompt** — did it change? Diff the prompt that ran against the last one that worked.
- **Session history** — what was in context at the failing turn? Read the actual transcript, not the intended one.
- **Long-term memory** — which entries were retrieved for this turn? Was a model-authored entry treated as a user-stated fact (memory contamination)?
- **Tool selection, execution and result interpretation** — was the right tool chosen, did the call actually run and return, and was the result read correctly or misread?
- **Hidden retry or repair loops** — does a second model call rewrite or "fix" the answer after the one you are looking at?
- **Transport** — timeouts, truncated or cut-off streams, a client that drops part of the response.
- **Stale state** — cached config, an old index or embedding store, state from a previous run reused as live.

Also check for a requirement that exists only in the prompt and nowhere in code — for example "always call the lookup tool first". Nothing enforces it, so the model can skip it silently.

The list orders the search; it is not a verdict. Assign the fault only to the layer the evidence names, and if the evidence names none, keep gathering.

When bisecting prompt or config revisions, first collapse revisions whose rendered prompt bytes are identical — they cannot differ in behavior. Bisect with the cheapest deterministic scorer (an exact match, a schema check, a regex on the output) and spend paid model judging only on the boundary pair it finds.

Output: 3-5 ranked, falsifiable hypotheses, most likely first. Each names what is wrong, why, and the observation that would refute it:

```
H1 (most likely): <claim> — refuted if <observation>
H2: ...
```

Show the ranked list once; the top one becomes **"Root cause hypothesis: ..."** for Phase 3. When `SESSION_KIND` is `spawned` or `headless`, skip printing the list and go straight to H1 — record the full list in the report instead.

### Refresh learnings for the hypothesis you just named

The top-of-skill learnings pull above is keyed to "debug investigation" broadly. Now that you have a specific hypothesis, re-pull learnings keyed to that hypothesis so prior fixes for the same problem-shape surface.

Pick ONE keyword from the hypothesis. The keyword should be a noun: the failing component name, the basename of the file you suspect (without extension), or the bug noun. The keyword MUST be alphanumeric or hyphen only — no quotes, slashes, dots, colons, or whitespace. If your candidate has any of those, simplify to just the alphanumeric stem.

Worked examples (investigate-specific): good keywords are `auth-cookie`, `session-expiry`, `redirect-loop`. Bad: `auth.ts:47`, `fix the auth bug`, `<hypothesis-keyword>`.

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --query "<your-keyword>" --limit 5 2>/dev/null || true
```

If any learnings come back, name which one applies to your investigation in one sentence. If none come back, continue without reference — the absence of a matching prior learning is itself useful information.

---

## Scope Lock

After forming your root cause hypothesis, lock edits to the affected module to prevent scope creep.

```bash
[ -x "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/investigate}/../freeze/bin/check-freeze.sh" ] && echo "FREEZE_AVAILABLE" || echo "FREEZE_UNAVAILABLE"
```

**If FREEZE_AVAILABLE:** Identify the narrowest directory containing the affected files. Acquire a run-owned boundary with the shared state writer. It resolves the physical absolute path and leaves any boundary the user (or another run) already set untouched:

```bash
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/investigate}/../freeze/bin/freeze-state.sh" acquire "<detected-directory>"
```

Substitute `<detected-directory>` with the actual directory path (e.g., `src/auth/`). Then act on the output:

- `FREEZE_OWNER=<token>` and `FREEZE_DIR=<path>` — this run owns a new lock. Keep the exact token for terminal cleanup; never reconstruct it from the state file. Tell the user: "Edits restricted to `<FREEZE_DIR>/` for this debug session. The lock is released when the investigation ends; `/unfreeze` removes it sooner."
- `FREEZE_PRESERVED` — a boundary was already set. Keep it, tell the user which boundary stays in force, and do not release it at the end.
- `FREEZE_ERROR` or `FREEZE_BUSY` (non-zero exit) — no lock was acquired. Report it before editing; never claim the scope is locked.

**Terminal cleanup:** When the investigation ends — completed, aborted, or stopped by an error — and this run holds a `FREEZE_OWNER` token, release it before the final response:

```bash
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/investigate}/../freeze/bin/freeze-state.sh" release "<retained-owner-token>"
```

The writer removes the state only if it still carries this run's token, so a boundary the user set in the meantime survives (`FREEZE_PRESERVED`). Report the result; never retry by deleting the state file directly. A session killed before cleanup leaves the lock in place — `/unfreeze` removes it.

If the bug spans the entire repo or the scope is genuinely unclear, skip the lock and note why.

**If FREEZE_UNAVAILABLE:** Skip scope lock. Edits are unrestricted.

---

## Phase 2: Pattern Analysis

Check if this bug matches a known pattern:

| Pattern | Signature | Where to look |
|---------|-----------|---------------|
| Race condition | Intermittent, timing-dependent | Concurrent access to shared state |
| Nil/null propagation | NoMethodError, TypeError | Missing guards on optional values |
| State corruption | Inconsistent data, partial updates | Transactions, callbacks, hooks |
| Integration failure | Timeout, unexpected response | External API calls, service boundaries |
| Configuration drift | Works locally, fails in staging/prod | Env vars, feature flags, DB state |
| Stale cache | Shows old data, fixes on cache clear | Redis, CDN, browser cache, Turbo |

**Working example diff:** When a similar path works (the same endpoint for another tenant, the previous release, a sibling component), diff the working and the failing case — inputs, config, code path, logged boundary values — and list every difference. The cause is in that list; each difference is a candidate hypothesis.

**When the failure is intermittent or CI-only:** read `${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/investigate}/flake.md` and follow it — base-vs-branch failure rates, a forced probe before any cause is named, order-dependent failures, races, and no loosened timeouts, retries or skips. Its `Flake evidence` block goes into the DEBUG REPORT.

Also check:
- `TODOS.md` for related known issues
- `git log` for prior fixes in the same area — **recurring bugs in the same files are an architectural smell**, not a coincidence

**External pattern search:** If the bug doesn't match a known pattern above, WebSearch for:
- "{framework} {generic error type}" — **sanitize first:** strip hostnames, IPs, file paths, SQL, customer data. Search the error category, not the raw message.
- "{library} {component} known issues"

If WebSearch is unavailable, skip this search and proceed with hypothesis testing. If a documented solution or known dependency bug surfaces, present it as a candidate hypothesis in Phase 3.

---

## Phase 3: Hypothesis Testing

Before writing ANY fix, verify your hypothesis.

1. **Confirm the hypothesis:** Add a temporary log statement, assertion, or debug output at the suspected root cause, tagged `[DEBUG-<short>]`. Run the `LOOP:` command. Does the evidence match what the hypothesis predicts, or its refutation?

   Change one variable per probe — one edit, one flag, one input — then run the loop, so the result names its cause. Revert a failed probe before the next one, and confirm `git diff` shows none of the probe (tagged logs may stay until Phase 5). For a performance bug, record a baseline measurement first, then bisect against it with `git bisect run <script that fails above the threshold>` — from a clean tree, and `git bisect reset` before the next step.

2. **If the hypothesis is wrong:** Before forming the next hypothesis, consider searching for the error. **Sanitize first** — strip hostnames, IPs, file paths, SQL fragments, customer identifiers, and any internal/proprietary data from the error message. Search only the generic error type and framework context: "{component} {sanitized error type} {framework version}". If the error message is too specific to sanitize safely, skip the search. If WebSearch is unavailable, skip and proceed. Then take the next ranked hypothesis, or return to Phase 1 when the list is spent. Gather more evidence. Do not guess.

3. **3-strike rule:** If 3 hypotheses fail, **STOP**. Use AskUserQuestion, naming the hypotheses still untested from the ranked list:
   ```
   3 hypotheses tested, none match. This may be an architectural issue
   rather than a simple bug. Untested: [H4, H5 — or none]

   A) Continue investigating — next: [an untested hypothesis, or a new one]
   B) Escalate for human review — this needs someone who knows the system
   C) Add logging and wait — instrument the area and catch it next time
   ```

**Red flags** — if you see any of these, slow down:
- "Quick fix for now" — there is no "for now." Fix it right or escalate.
- Proposing a fix before tracing data flow — you're guessing.
- Each fix reveals a new problem elsewhere — wrong layer, not wrong code.

---

## Phase 4: Implementation

Once root cause is confirmed:

1. **Write the regression test first**, from the minimised repro, at a correct seam: the public boundary that owns the broken behavior, through the interface real callers use. If no such seam exists without adding a test-only hook, that is a finding — record it in the report and suggest `/improve-arch`; test at the nearest real boundary meanwhile.

2. **Run it red on its own assertion**, against the unfixed code, and paste the failing line. An import, fixture or setup error is not red; correct the test and re-run.

3. **Fix the root cause, not the symptom.** The smallest change that eliminates the actual problem. Fewest files touched, fewest lines changed. Resist the urge to refactor adjacent code.

4. **Run the regression test green**, then **Run the full test suite.** Paste the output. No regressions allowed.

5. **If the fix touches >5 files:** Use AskUserQuestion to flag the blast radius:
   ```
   This fix touches N files. That's a large blast radius for a bug fix.
   A) Proceed — the root cause genuinely spans these files
   B) Split — fix the critical path now, defer the rest
   C) Rethink — maybe there's a more targeted approach
   ```

{{include lib/snippets/test-value-bar.md}}

---

## Phase 5: Verification & Report

**Release the scope lock first:** If this run acquired a scope lock, run the terminal cleanup from **Scope Lock** now. The tagged lines can sit outside the locked directory, and the remaining steps edit nothing but them.

**Remove instrumentation:** Delete every tagged log line, then confirm none remain — this must print nothing:

```bash
git grep -n '\[DEBUG-<short>\]'
```

**Fresh verification:** Run the `LOOP:` command and confirm it is green, reproduce the original bug scenario, then run the test suite and paste the output. This is not optional. The last edit precedes the last run: any edit after the suite ran — including removing instrumentation — means run it again.

Output a structured debug report. A field with nothing to report says `none: <reason>`, never blank:
```
DEBUG REPORT
════════════════════════════════════════
Symptom:              [what the user observed]
Loop:                 [the LOOP: line]
Hypothesis confirmed: [H<n>: claim — the evidence that confirmed it; refuted ones listed after]
Root cause:           [what was actually wrong]
Fix:                  [what was changed, with file:line references]
Evidence:             [test output, reproduction attempt showing fix works]
Regression test:      [file:line of the new test]
Regression proof:     [the value bar's Regression proof line, plus the failing assertion and the full suite result]
Blast radius:
  Safety fact:        [one sentence: what this fix cannot affect, and why]
  Evidence rung:      [said → file:line → walked → ran → reproduced — the highest one reached]
  Confirmed risks:    [callers or paths shown to be affected, with evidence]
  Cleared risks:      [paths checked and shown unaffected, with evidence]
Related:              [TODOS.md items, prior bugs in same area, architectural notes]
Status:               DONE | DONE_WITH_CONCERNS | BLOCKED
════════════════════════════════════════
```

Evidence rungs, weakest first: **said** (someone asserted it), **file:line** (you read the code), **walked** (you traced every caller), **ran** (a command exercised the path), **reproduced** (the loop showed it before and after). Name the rung honestly; a risk cleared only at **said** is not cleared.

Log the investigation as a learning for future sessions. Use `type: "investigation"` and include the affected files so future investigations on the same area can find this. Write the JSON to a file first and run the **Redact** scan on it; log it only on `REDACT_EXIT: 0`:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-log" '{"skill":"investigate","type":"investigation","key":"ROOT_CAUSE_KEY","insight":"ROOT_CAUSE_SUMMARY","confidence":9,"source":"observed","files":["affected/file1.ts","affected/file2.ts"]}'
```

{{include lib/snippets/capture-learnings.md}}
## Important Rules

- **3+ failed fix attempts → STOP and question the architecture.** Wrong architecture, not failed hypothesis.
- **Never apply a fix you cannot verify.** If you can't reproduce and confirm, don't ship it.
- **Never say "this should fix it."** Verify and prove it. Run the tests.
- **If fix touches >5 files → AskUserQuestion** about blast radius before proceeding.
- **Completion status:**
  - DONE — root cause found, fix applied, regression test written, all tests pass
  - DONE_WITH_CONCERNS — fixed but cannot fully verify (e.g., intermittent bug, requires staging)
  - BLOCKED — root cause unclear after investigation, escalated
