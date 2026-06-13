## EXIT PLAN MODE GATE (BLOCKING)

Before calling ExitPlanMode, run this self-check. If a plan file is in context for this skill invocation and any item fails, do the missing work — do NOT call ExitPlanMode. If no plan file is in context, this gate short-circuits (checks 1–4 already short-circuit when no plan file exists).

1. Read the plan file with the Read tool (after your most recent write to it).
2. Confirm the LAST `## ` heading in the file is `## VIBESTACK REVIEW REPORT`. In-body prose mentioning "outside voice", "codex findings", or similar does NOT satisfy this — only the structured `## VIBESTACK REVIEW REPORT` section does.
3. Confirm the report has the Runs / Status / Findings table and a VERDICT line (CODEX / CROSS-MODEL absorbed when applicable).
4. Confirm the report's FINAL non-whitespace line is the unresolved-decisions status: the exact unbolded `NO UNRESOLVED DECISIONS`, or a bullet of a final `**UNRESOLVED DECISIONS:**` block. BLOCKING — there is no "if applicable" escape. A bolded sentinel, any trailing CODEX / CROSS-MODEL / VERDICT / prose line, or a missing status each FAILS the gate.
5. If a plan file is in context: confirm `vibe-review-log` was called and `vibe-review-read` ran at least once this invocation.

Calling ExitPlanMode with this gate failing is a contract violation — the user would see a plan whose review report is missing or stale, and would correctly reject it.
