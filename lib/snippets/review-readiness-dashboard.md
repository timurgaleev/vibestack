## Review Readiness Dashboard

After completing the review, gather the four inputs the dashboard needs — the
review log, a snapshot of the working tree, the current commit, and the global
skip setting:

```bash
${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-read --json 2>/dev/null
echo "TREE_NOW: $(${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-review-log --snapshot 2>/dev/null || echo unavailable)"
git rev-parse --short HEAD
${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-config get skip_eng_review 2>/dev/null
```

`vibe-review-read --json` prints exactly one of two things: the literal
`NO_REVIEWS` when this branch has no review log yet, or a single JSON array
holding every logged entry for the branch, oldest first. Its output carries no
other sections — take the tree, the commit and the skip setting from their own
commands above, never from a trailer on the review output. Treat `NO_REVIEWS` and an
empty array `[]` the same: every row shows 0 runs and `—`, and the verdict falls
through to the Eng Review rule below. `vibe-config get` prints `true` when the
skip is set and nothing at all when it is unset.

Parse the array. Find the most recent entry for each skill (plan-ceo-review, plan-eng-review, review, plan-design-review, design-review-lite, adversarial-review, codex-review, codex-plan-review). Ignore entries with timestamps older than 7 days. For the Eng Review row, show whichever is more recent between `review` (diff-scoped pre-landing review) and `plan-eng-review` (plan-stage architecture review). Append "(DIFF)" or "(PLAN)" to the status to distinguish. For the Adversarial row, show whichever is more recent between `adversarial-review` (new auto-scaled) and `codex-review` (legacy). For Design Review, show whichever is more recent between `plan-design-review` (full visual audit) and `design-review-lite` (code-level check). Append "(FULL)" or "(LITE)" to the status to distinguish. For the Outside Voice row, show the most recent `codex-plan-review` entry — this captures outside voices from both /plan-ceo-review and /plan-eng-review.

**Source attribution:** If the most recent entry for a skill has a \`"via"\` field, append it to the status label in parentheses. Examples: `plan-eng-review` with `via:"autoplan"` shows as "CLEAR (PLAN via /autoplan)". `review` with `via:"ship"` shows as "CLEAR (DIFF via /ship)". Entries without a `via` field show as "CLEAR (PLAN)" or "CLEAR (DIFF)" as before.

Note: `autoplan-voices` and `design-outside-voices` entries are audit-trail-only (forensic data for cross-model consensus analysis). They do not appear in the dashboard and are not checked by any consumer.

Display:

```
+====================================================================+
|                    REVIEW READINESS DASHBOARD                       |
+====================================================================+
| Review          | Runs | Last Run            | Status    | Required |
|-----------------|------|---------------------|-----------|----------|
| Eng Review      |  1   | 2026-03-16 15:00    | CLEAR     | YES      |
| CEO Review      |  0   | —                   | —         | no       |
| Design Review   |  0   | —                   | —         | no       |
| Adversarial     |  0   | —                   | —         | no       |
| Outside Voice   |  0   | —                   | —         | no       |
+--------------------------------------------------------------------+
| VERDICT: CLEARED — Eng Review passed                                |
+====================================================================+
```

**Review tiers:**
- **Eng Review (required by default):** The only review that gates shipping. Covers architecture, code quality, tests, performance. Can be disabled globally with \`vibe-config set skip_eng_review true\` (the "don't bother me" setting).
- **CEO Review (optional):** Use your judgment. Recommend it for big product/business changes, new user-facing features, or scope decisions. Skip for bug fixes, refactors, infra, and cleanup.
- **Design Review (optional):** Use your judgment. Recommend it for UI/UX changes. Skip for backend-only, infra, or prompt-only changes.
- **Adversarial Review (automatic):** Always-on for every review. Every diff gets both Claude adversarial subagent and Codex adversarial challenge. Large diffs (200+ lines) additionally get Codex structured review with P1 gate. No configuration needed.
- **Outside Voice (optional):** Independent plan review from a different AI model. Offered after all review sections complete in /plan-ceo-review and /plan-eng-review. Falls back to Claude subagent if Codex is unavailable. Never gates shipping.

**Verdict logic:**
- **CLEARED**: Eng Review has >= 1 entry within 7 days from either \`review\` or \`plan-eng-review\` with status "clean" (or \`skip_eng_review\` is \`true\`)
- **NOT CLEARED**: Eng Review missing, stale (>7 days), or has open issues
- **Tree binding.** A `review` or `plan-eng-review` entry that carries a `tree` field counts toward CLEARED only when that `tree` equals `TREE_NOW`, and neither `completed` nor `converged` is `false`. A different tree shows "CLEAN (tree changed since review)" and does not clear: the content in front of you is not the content that was reviewed, whether or not HEAD moved. `TREE_NOW: unavailable` means no tree-bound entry clears. An entry whose `tree` is `null` (the logger could not fingerprint the tree) has unknown freshness: show "CLEAN (freshness unknown)" and it does not clear — it never falls back to the commit check. Status `incomplete` (a reviewer never finished) and status `unverified` (logged clean without a tree) are never clean. Entries without `tree` (older logs) fall back to the commit-based staleness note below.
- CEO, Design, and Codex reviews are shown for context but never block shipping
- If \`skip_eng_review\` config is \`true\`, Eng Review shows "SKIPPED (global)" and verdict is CLEARED

**Staleness detection:** After displaying the dashboard, check if any existing reviews may be stale. Content decides, not commits: a commit, amend or rebase that keeps the bytes keeps the review current, and an uncommitted edit makes it stale even though HEAD never moved.
- For each review entry that has a `tree` field: if its `tree` is `null`, display: "Note: {skill} review from {date} was logged without a tree fingerprint, so freshness is unknown". Otherwise compare it with `TREE_NOW`. If different, display: "Note: {skill} review from {date} is stale — the working tree changed since it was logged". If `TREE_NOW` is `unavailable`, display: "Note: {skill} review from {date} — the current tree cannot be fingerprinted, so freshness is unknown". Skip the commit checks below for these entries
- For the remaining entries, use the short hash from the `git rev-parse --short HEAD` command above as the current commit. The review log does not report HEAD, so there is nothing to parse out of `vibe-review-read` for this
- For each such entry that has a `commit` field: compare it against the current HEAD. If different, count elapsed commits: `git rev-list --count STORED_COMMIT..HEAD`. Display: "Note: {skill} review from {date} may be stale — {N} commits since review"
- If that `git rev-list` fails, the stored commit is no longer in this history — a rebase, squash, or amend rewrote it. Display: "Note: {skill} review from {date} predates a history rewrite — treat it as stale" rather than reporting a commit count
- For entries with neither `tree` nor `commit` (legacy entries), or whose `commit` is the string `unknown` (git was unreachable when the entry was written): display "Note: {skill} review from {date} has no commit tracking — consider re-running for accurate staleness detection"
- If every review matches `TREE_NOW` (or, for entries without `tree`, the current HEAD), do not display any staleness notes
