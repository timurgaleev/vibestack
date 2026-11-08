### Detect stack and scope

```bash
# Compute SCOPE_* signals from the diff (drives conditional specialist dispatch).
# Cleared first: a flag left in the environment must never select. A failed or
# missing scope reads SCOPE_UNAVAILABLE=true, never all-false.
unset SCOPE_FRONTEND SCOPE_BACKEND SCOPE_PROMPTS SCOPE_TESTS SCOPE_DOCS SCOPE_CONFIG SCOPE_MIGRATIONS SCOPE_API SCOPE_AUTH SCOPE_UNAVAILABLE
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-diff-scope" <base> 2>/dev/null || true)"
[ -n "${SCOPE_FRONTEND:-}${SCOPE_UNAVAILABLE:-}" ] || SCOPE_UNAVAILABLE=true
echo "SCOPE_FRONTEND=${SCOPE_FRONTEND:-false} SCOPE_BACKEND=${SCOPE_BACKEND:-false} SCOPE_AUTH=${SCOPE_AUTH:-false} SCOPE_MIGRATIONS=${SCOPE_MIGRATIONS:-false} SCOPE_API=${SCOPE_API:-false} SCOPE_UNAVAILABLE=${SCOPE_UNAVAILABLE:-false}"
# Detect stack for specialist context
STACK=""
[ -f Gemfile ] && STACK="${STACK}ruby "
[ -f package.json ] && STACK="${STACK}node "
[ -f requirements.txt ] || [ -f pyproject.toml ] && STACK="${STACK}python "
[ -f go.mod ] && STACK="${STACK}go "
[ -f Cargo.toml ] && STACK="${STACK}rust "
echo "STACK: ${STACK:-unknown}"
DIFF_INS=$(git diff $(git merge-base origin/<base> HEAD) --stat | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
DIFF_DEL=$(git diff $(git merge-base origin/<base> HEAD) --stat | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
# New files not yet added are invisible to git diff --stat; count their lines too.
UNTRACKED_LINES=$(git ls-files -z --others --exclude-standard | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')
DIFF_LINES=$((DIFF_INS + DIFF_DEL + ${UNTRACKED_LINES:-0}))
echo "DIFF_LINES: $DIFF_LINES"
# Detect test framework for specialist test stub generation
TEST_FW=""
{ [ -f jest.config.ts ] || [ -f jest.config.js ]; } && TEST_FW="jest"
[ -f vitest.config.ts ] && TEST_FW="vitest"
{ [ -f spec/spec_helper.rb ] || [ -f .rspec ]; } && TEST_FW="rspec"
{ [ -f pytest.ini ] || [ -f conftest.py ]; } && TEST_FW="pytest"
[ -f go.mod ] && TEST_FW="go-test"
echo "TEST_FW: ${TEST_FW:-unknown}"
```

### Read specialist hit rates (adaptive gating)

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-specialist-stats" 2>/dev/null || true
```

Each line tags a specialist `GATE_CANDIDATE` (dispatched 10+ times, never found
anything — safe to skip), `NEVER_GATE` (security / data-migration insurance —
always run), or `active`. Fresh project with no history → everything is `active`,
so the full scope-selected set runs.

### Select specialists

Based on the scope signals above, select which specialists to dispatch. Each
checklist is `<name>.md` in `${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/{SKILL_NAME}}/../review/specialists/`
(the installed review skill, never a path relative to the repo under review).

**If `SCOPE_UNAVAILABLE=true`:** the scope could not be computed, so dispatch every specialist below: neither the small-diff skip nor adaptive gating applies. An unknown scope is not an empty one.

**Always-on (dispatch on every review with 50+ changed lines):**
1. **Testing** — `testing.md`
2. **Maintainability** — `maintainability.md`

**If DIFF_LINES < 50:** Skip all specialists except Targeted (9). Print: "Small diff ($DIFF_LINES lines) — specialists skipped." Continue with the next step.

**Conditional (dispatch if the matching scope signal is true):**
3. **Security** — `security.md`, if SCOPE_AUTH=true, OR if SCOPE_BACKEND=true AND DIFF_LINES > 100.
4. **Performance** — `performance.md`, if SCOPE_BACKEND=true OR SCOPE_FRONTEND=true.
5. **Data Migration** — `data-migration.md`, if SCOPE_MIGRATIONS=true.
6. **API Contract** — `api-contract.md`, if SCOPE_API=true.
7. **Design** — if SCOPE_FRONTEND=true. Use the design review checklist at `${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/{SKILL_NAME}}/../review/design-checklist.md`.
8. **Simplification** — `simplification.md`, if DIFF_LINES > 100. Advisory-only lens: it hunts structure nobody asked for (hand-rolled stdlib, one-implementation abstractions, dependencies duplicating platform features), never missing coverage.
9. **Targeted** — `targeted.md`, regardless of DIFF_LINES, when SCOPE_AUTH=true or the diff matches `grep -Eiq '(openai|anthropic|bedrock|stripe|twilio)|(^|[^[:alnum:]_])(caps?|limits?|budgets?|quota|tokens?|secrets?|redact)'`. Never gated.

### Adaptive gating

After scope-based selection, apply adaptive gating based on specialist hit rates:

For each conditional specialist that passed scope gating, check the specialist stats output above:
- If tagged `[GATE_CANDIDATE]` (0 findings in 10+ dispatches): skip it. Print: "[specialist] auto-gated (0 findings in N reviews)."
- If tagged `[NEVER_GATE]`: always dispatch regardless of hit rate. Security and data-migration are insurance policy specialists — they should run even when silent.

**Force flags:** If the user's prompt includes `--security`, `--performance`, `--testing`, `--maintainability`, `--data-migration`, `--api-contract`, `--design`, `--simplification`, or `--all-specialists`, force-include that specialist regardless of gating.

Note which specialists were selected, gated, and skipped. Print the selection:
"Dispatching N specialists: [names]. Skipped: [names] (scope not detected). Gated: [names] (0 findings in N+ reviews)."

---

### Dispatch specialists in parallel

For each selected specialist, launch an independent subagent via the Agent tool with `run_in_background: false`.
**Launch ALL selected specialists in a single message** (multiple Agent tool calls)
so they run in parallel. Each subagent has fresh context — no prior review bias.

**Each specialist subagent prompt:**

Construct the prompt for each specialist. The prompt includes:

1. The specialist's checklist content (you already read the file above)
2. Stack context: "This is a {STACK} project."
3. Past learnings for this domain (if any exist):

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --type pitfall --query "{specialist domain}" --limit 5 2>/dev/null || true
```

If learnings are found, include them: "Past learnings for this domain: {learnings}"

4. Instructions:

"You are a specialist code reviewer. Read the checklist below, then run
`git diff $(git merge-base origin/<base> HEAD)` to get the full diff. Then run `git ls-files --others --exclude-standard` and read each listed source file in full — new files not yet added are part of the change and git diff does not show them. Apply the checklist against the diff and those files.

For each finding, output a JSON object on its own line:
{\"severity\":\"CRITICAL|INFORMATIONAL\",\"confidence\":N,\"path\":\"file\",\"line\":N,\"category\":\"category\",\"summary\":\"description\",\"fix\":\"recommended fix\",\"fingerprint\":\"path:line:category\",\"specialist\":\"name\"}

Required fields: severity, confidence, path, category, summary, specialist.
Optional: line, fix, fingerprint, evidence, test_stub, cause ({\"path\":\"file\",\"line\":N} where the root cause sits, when it is not the flagged line).

If you can write a test that would catch this issue, include it in the `test_stub` field.
Use the detected test framework ({TEST_FW}). Write a minimal skeleton — describe/it/test
blocks with clear intent. Skip test_stub for architectural or design-only findings.

If no findings: output `NO FINDINGS` and nothing else.
Do not output anything else — no preamble, no summary, no commentary.

Stack context: {STACK}
Past learnings: {learnings or 'none'}

CHECKLIST:
{checklist content}"

**Subagent configuration:**
- Use `subagent_type: "general-purpose"`
- Pass `run_in_background: false` on every specialist Agent call: a background call
  returns at once with nothing, the merge sees an empty set, and the run reports a
  clean review it never performed.
- If any specialist subagent fails, times out, or returns output that is neither JSON
  findings nor `NO FINDINGS`, keep the findings from the specialists that did finish, but
  name the failed specialist in the output (`Specialist <name>: NO COVERAGE — <reason>`)
  and mark the run **incomplete**: its `specialists` entry gets `"completed":false` and
  the review persist records `completed:false`. Missing or unusable output is incomplete
  coverage, never an empty success.

---

### Collect and merge findings

After all specialist subagents complete, collect their outputs.

**Parse findings:**
For each specialist's output:
1. If output is "NO FINDINGS" — skip, this specialist found nothing
2. Otherwise, parse each line as a JSON object. Skip lines that are not valid JSON.
3. Collect all parsed findings into a single list, tagged with their specialist name.

**Fingerprint and deduplicate:**
For each finding, compute its fingerprint:
- If `fingerprint` field is present, use it
- Otherwise: `{path}:{line}:{category}` (if line is present) or `{path}:{category}`

Group findings by fingerprint. For findings sharing the same fingerprint:
- Keep the finding with the highest confidence score
- Tag it: "MULTI-SPECIALIST CONFIRMED ({specialist1} + {specialist2})"
- Boost confidence by +1 (cap at 10)
- Note the confirming specialists in the output

**Lead judgment:** drop findings whose only weight is a nit, hypotheticals no call site reaches,
and "a different design would be better" with no failing case; merge findings sharing a `cause`.

**Keep advisory findings advisory:**
Simplification findings are taste, not defects. Force every one of them to
`INFORMATIONAL` no matter what severity the subagent emitted, keep them out of the
critical count, and never route them through Fix-First auto-fix — they are proposals
the user accepts or ignores. A multi-specialist match that includes simplification
takes the other specialist's severity, not a boosted one. Leave them out of the PR
Quality Score as well — a score that drops because the diff was offered a simpler
shape would teach the next run to stop offering.

**Apply confidence gates:** the Confidence Calibration display rules decide what is shown, caveated, moved to the appendix or dropped.

**Compute PR Quality Score:**
After merging, compute the quality score:
`quality_score = max(0, 10 - (critical_count * 2 + informational_count * 0.5))`
Cap at 10. Log this in the review result at the end.

**Output merged findings:**

```
SPECIALIST REVIEW: N findings (X critical, Y informational) from Z specialists

[For each finding, in order: CRITICAL first, then INFORMATIONAL, sorted by confidence descending]
[SEVERITY] (confidence: N/10, specialist: name) path:line — summary
  Fix: recommended fix
  [If MULTI-SPECIALIST CONFIRMED: show confirmation note]

PR Quality Score: X/10
[If simplification ran: "Simplification: N advisory notes — suggestions, not blockers."]
```

These findings join the checklist-pass findings in the Fix-First pass, under the same
AUTO-FIX vs ASK classification.

**Compile per-specialist stats** for the review-log persist.
For each specialist (testing, maintainability, security, performance, data-migration, api-contract, design, simplification, targeted, red-team):
- If dispatched: `{"dispatched": true, "completed": true, "findings": N, "critical": N, "informational": N}` — `"completed": false` when it failed, timed out or returned unusable output (its counts are then 0 and mean nothing)
- If skipped by scope: `{"dispatched": false, "reason": "scope"}`
- If skipped by gating: `{"dispatched": false, "reason": "gated"}`
- If not applicable (e.g., red-team not activated): omit from the object

Include the Design specialist even though it uses `design-checklist.md` instead of the specialist schema files.

---

### Red Team dispatch (conditional)

**Activation:** Only if DIFF_LINES > 200 OR any specialist produced a CRITICAL finding.

If activated, dispatch one more subagent via the Agent tool with `run_in_background: false` — the same foreground rule as the specialists above, for the same reason.

The Red Team subagent receives:
1. The red-team checklist, `red-team.md` in the specialists directory above
2. The merged specialist findings (so it knows what was already caught)
3. The git diff command

Prompt: "You are a red team reviewer. The code has already been reviewed by N specialists
who found the following issues: {merged findings summary}. Your job is to find what they
MISSED. Read the checklist, run `git diff $(git merge-base origin/<base> HEAD)`, read the
untracked files listed by `git ls-files --others --exclude-standard`, and look for gaps.
Output findings as JSON objects (same schema as the specialists). Focus on cross-cutting
concerns, integration boundary issues, and failure modes that specialist checklists
don't cover."

Merge any Red Team findings into the list before Fix-First, tagged `"specialist":"red-team"`.

If the Red Team returns NO FINDINGS, note: "Red Team review: no additional issues found."
If the Red Team subagent fails, times out, or returns unusable output, say so —
`Red Team: NO COVERAGE — <reason>` — and continue. An activated Red Team that did not
finish makes the run incomplete (the persist records `completed:false`); it is never
reported as "no additional issues found".
