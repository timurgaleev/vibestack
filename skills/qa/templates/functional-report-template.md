# Functional QA Report: {PROJECT_NAME}

| Field | Value |
|-------|-------|
| **Date** | {DATE} |
| **Branch** | {BRANCH} |
| **Commit** | {COMMIT_SHA} ({COMMIT_DATE}) |
| **Surface** | functional / mixed (functional part) |
| **Mode** | Full / Quick / Regression |
| **Target** | {CLI, library, endpoint or job under test} |
| **Isolation** | {scratch dir, test database or local instance the probes wrote to} |
| **Duration** | {DURATION} |

## Outcomes

| Outcome | Rows |
|---------|------|
| pass | {N} |
| fail | {N} |
| blocked | {N} |
| not run | {N} |
| inconclusive | {N} |

Only `pass` rows were verified. `blocked`, `not run` and `inconclusive` are not passes.

## Contract Map

| Row | Behavior | Expectation (written before the run) | Outcome |
|-----|----------|--------------------------------------|---------|
| R1 | {behavior} | {input → observable outcome and durable effect} | pass / fail / blocked / not run / inconclusive |

## Failed Rows

### ISSUE-001 (R{N}): {Short title}

| Field | Value |
|-------|-------|
| **Severity** | critical / high / medium / low |
| **Category** | functional |
| **Row** | R{N} |

**Expected:** {the pre-written expectation}

**Observed:** {what happened}

**Evidence:**

```
$ {exact command}
exit: {code}
stdout: {relevant lines, secrets redacted}
stderr: {relevant lines, secrets redacted}
read-back: {command and result}
```

**Replayed:** yes / no — {same starting state, same result?}

---

## Blocked, Not Run and Inconclusive

| Row | Outcome | Reason |
|-----|---------|--------|
| R{N} | blocked / not run / inconclusive | {missing prerequisite, why skipped, or what could not be decided} |

## Regression (if applicable)

| Row | Baseline | Current |
|-----|----------|---------|
| R{N} | {outcome} | {outcome} |
