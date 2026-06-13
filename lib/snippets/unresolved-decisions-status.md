**Unresolved-decisions status (MANDATORY — never omitted; must be the report's final non-whitespace line).** End the `## VIBESTACK REVIEW REPORT` section with exactly one of:

- the exact unbolded line `NO UNRESOLVED DECISIONS` (a **bolded** version does NOT count), when this review AND all prior fresh reviews have zero unresolved decisions; or
- a `**UNRESOLVED DECISIONS:**` header followed by one bullet per open decision, each naming what breaks if the plan ships with that decision deferred. The last bullet is the final line of the report.

This status is exempt from any "omit when empty" rule above — it is always written, and nothing may follow it (no CODEX / CROSS-MODEL / VERDICT line, no trailing prose). To count prior reviews, sum the `unresolved` field of the most recent fresh entry (within the 7-day window) per review skill, excluding the review you just ran; when that sum is N > 0, append ` + N unresolved from prior reviews` to the `**UNRESOLVED DECISIONS:**` header. Emit the `NO UNRESOLVED DECISIONS` sentinel only when both this review's and the prior count are zero.
