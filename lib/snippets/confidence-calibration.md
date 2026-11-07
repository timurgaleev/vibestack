Every finding MUST carry a severity and a confidence score (1-10).

**Severity:**

| Level | Meaning |
|-------|---------|
| **P0** | Release-blocking catastrophe: data loss, a security breach, an outage. |
| **P1** | Must fix before merge: a real bug or exploit on a reachable path. |
| **P2** | Should fix: a likely defect, a missing guard, a maintenance trap. |
| **P3** | Minor: worth noting, safe to defer. |

P0 and P1 are CRITICAL; P2 and P3 are INFORMATIONAL.

**Confidence:**

| Score | Meaning | Display rule |
|-------|---------|-------------|
| 9-10 | Verified by reading specific code. Concrete bug or exploit demonstrated. | Show normally |
| 7-8 | High confidence pattern match. Very likely correct. | Show normally |
| 5-6 | Moderate. Could be a false positive. | Show with caveat: "Medium confidence, verify this is actually an issue" |
| 3-4 | Low confidence. Pattern is suspicious but may be fine. | Suppress from main report. Include in appendix only. |
| 1-2 | Speculation, though the motivating line is quoted. | Report only a release-blocking catastrophe, labelled CRITICAL and speculative: `[P0] (confidence: 2/10, speculative)`. Drop anything else. An unquoted finding never lands here; the gate below sets it to 4 or 5. |

**Finding format:**

`[SEVERITY] (confidence: N/10) file:line — description`

Example:
`[P1] (confidence: 9/10) app/models/user.rb:42 — SQL injection via string interpolation in where clause`
`[P2] (confidence: 5/10) app/controllers/api/v1/users_controller.rb:18 — Possible N+1 query, verify with production logs`

### Pre-emit verification gate (kills the "field doesn't exist" FP class)

Before any finding is promoted to the report, the gate requires:

1. **Quote the specific code line that motivates the finding** — file:line plus
   the verbatim text of the line(s) that triggered it. If the finding is "field
   X doesn't exist on model Y", quote the lines of class Y where the field
   would live. If "dict.get() might return None", quote the dict initialization.
   If "race condition between A and B", quote both A and B.

2. **If you cannot quote the motivating line(s), the finding is unverified.**
   Force its confidence to exactly one of:

   - **4** — keep it out of the main report; list it in the appendix so reviewers can audit calibration.
   - **5** — show it in the main report with the caveat "Medium confidence, verify this is actually an issue".

   Pick 5 when the finding would be P0 or P1 if real, so the user sees it and
   can check it; otherwise 4. Never raise an unverified finding to 7+ — that
   defeats the gate.
