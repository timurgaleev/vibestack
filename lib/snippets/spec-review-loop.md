## Spec Review Loop

Before presenting the document to the user for approval, run an adversarial review.

**Step 1: Dispatch reviewer subagent**

Use the Agent tool to dispatch an independent reviewer. The reviewer has fresh context
and cannot see the brainstorming conversation — only the documents named below. This ensures genuine
adversarial independence. Pass `run_in_background: false` on the Agent call (wherever the
tool accepts it) and wait for the reviewer to return — a backgrounded reviewer hands back
control before its score exists, and the loop would read that silence as a PASS.

Prompt the subagent with:
- The file path of the document just written
- The path of every source document the calling skill names for this review (for
  example, the plan the document summarizes). The reviewer judges the document against
  those sources, not only against itself.
- From round 2 on, the previous round's issue list.
- "Read this document and review it on 5 dimensions. For each dimension, note PASS or
  list specific issues with suggested fixes. Tag every issue `blocking` (a builder would
  build the wrong thing or get stuck) or `minor` (polish). At the end, output a quality
  score (1-10) across all dimensions. If a file you were given is missing, empty or cut
  off, output `INPUT_INCOMPLETE: <path> — <what is missing>` and do not grade it. List
  **Builder questions**: the places a builder would have to guess, most consequential
  first. If you were given previous issues, mark each one `resolved` or `persisting`
  against the current text."

**Dimensions:**
1. **Completeness** — Are all requirements addressed? Missing edge cases?
2. **Consistency** — Do parts of the document agree with each other? Contradictions?
3. **Clarity** — Could an engineer implement this without asking questions? Ambiguous language?
4. **Scope** — Does the document creep beyond the original problem? YAGNI violations?
5. **Feasibility** — Can this actually be built with the stated approach? Hidden complexity?

The subagent should return:
- A quality score (1-10), or `INPUT_INCOMPLETE` instead of a score
- PASS if no issues, or a numbered list of issues with dimension, severity, description, and fix
- Builder questions, ranked (possibly none)
- From round 2 on, each previous issue marked `resolved` or `persisting`

`INPUT_INCOMPLETE` is never a PASS: supply the missing input and re-dispatch. That
round counts toward the cap.

**Step 2: Fix and re-dispatch**

Fix only `blocking` issues; `minor` issues go straight to Reviewer Concerns, unfixed.

How a fix lands is set by the calling skill's **fix policy**, stated just before this
section. With no stated policy it is `auto-fix`.
- `auto-fix` — fix each issue in the document on disk (use Edit tool).
- `propose` — edit nothing on your own. Present each issue and its suggested fix as its
  own AskUserQuestion: **A)** Apply this fix **B)** Leave it as is (record it as a
  Reviewer Concern). Apply only the approved fixes. An issue the user declines is not
  re-raised on later iterations.

If the reviewer returns blocking issues or `INPUT_INCOMPLETE`:
1. Resolve each blocking issue under the fix policy above (for `INPUT_INCOMPLETE`,
   supply the missing input)
2. Re-dispatch the reviewer subagent with the updated document and this round's issue
   list, again with `run_in_background: false`
3. Maximum 3 iterations total

**Convergence guard:** If an issue comes back `persisting` on consecutive iterations
(the fix didn't resolve it or the reviewer disagrees with the fix), stop the loop
and persist those issues as "Reviewer Concerns" in the document rather than looping
further.

**Cap check:** If the loop ends at the cap, re-read the amended document and check each
fix you applied against its text. Report "issues confirmed resolved k/N" (N = fixes
applied); a fix that did not hold becomes a Reviewer Concern.

If the subagent fails, times out, or is unavailable on the first round — skip the review
loop entirely. Tell the user: "Spec review unavailable — presenting unreviewed doc." On a
later round, stop there and keep every Reviewer Concern already gathered; tell the user
the review stopped at round N. The document is already written to disk; the review is a
quality bonus, not a gate.

**Builder questions:** sort the last round's list. Answered in this session — write the
answer into the document. Minor — decide, write it in, and mark it "(my call)" (under
`propose`, ask instead). User-only — ask in one AskUserQuestion batch,
at most 4 questions per call (more go in the next call, never dropped), then write the
answers in.

**Step 3: Report and persist metrics**

After the loop completes (PASS, max iterations, convergence guard, or a stopped review):

If no round produced a grade — every round returned `INPUT_INCOMPLETE`, or the
missing input cannot be supplied — the document was never reviewed. Say "Spec
review unavailable — presenting unreviewed doc." and log no score; never report
it as having survived any rounds.

1. Tell the user the result — summary by default:
   "Your doc survived N rounds of adversarial review. M issues caught and fixed.
   Quality score: X/10." At the cap, add "issues confirmed resolved k/N".
   If the reviewer never returned a score, say so ("no score") rather than inventing one.
   If they ask "what did the reviewer find?", show the full reviewer output.

2. If any Reviewer Concerns were gathered (minor, persisting, declined, or fixes that did
   not hold), add a "## Reviewer Concerns" section to the document listing each one.
   Downstream skills will see this.

3. Append metrics:
```bash
mkdir -p "${VIBESTACK_HOME:-$HOME/.vibestack}/analytics"
echo '{"skill":"{SKILL_NAME}","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","iterations":ITERATIONS,"issues_found":FOUND,"issues_fixed":FIXED,"remaining":REMAINING,"quality_score":SCORE}' >> "${VIBESTACK_HOME:-$HOME/.vibestack}/analytics/spec-review.jsonl" \
  || echo "SPEC_REVIEW_METRICS_NOT_PERSISTED (exit $?)"
```
Replace ITERATIONS, FOUND, FIXED, REMAINING, SCORE with actual values from the review;
SCORE is `null` when the reviewer returned no score. If the block prints
`SPEC_REVIEW_METRICS_NOT_PERSISTED`, tell the user the metrics were not saved and why —
never report them as recorded.
