## Functional surface

Use this section when the surface is functional, and for the functional part of
a mixed surface. For that part it replaces the browser's Authenticate, Orient
and Explore steps; the run directory, the probe rules and the report rules
still apply. The mode comes from the same flags:

- **Full** — every row of the contract map.
- **Quick** — for each changed behavior, its success row and one failure row.
- **Regression** — rerun every row of the prior baseline with the same
  commands and compare outcomes row by row.

### Contract map

Before running anything, write the contract map into the report: one row per
behavior the change touches, found read-only from the diff, the docs, `--help`
output, handler signatures and existing tests. Each row carries a pre-written
expectation — one sentence naming the input and the observable outcome — set
down before you run it, so the result is checked against a prediction rather
than explained after the fact. Cover each kind that applies and mark the rest
`n/a — <reason>`:

- **Success and durable effect** — the happy path and the effect it must leave
  (a file, a row, a message, a mail in a test sink), read back by a separate
  command.
- **Input rules** — one probe per input rule, so one rejection never stands in
  for another.
- **Authorization** — no credentials, another user's resource, too little
  role: each is refused and nothing is written.
- **CLI contract** — exit code, stdout and stderr asserted separately: a
  failure exits non-zero and explains on stderr; stdout documented as
  machine-readable stays parseable.
- **State transitions** — each allowed transition works; a disallowed one is
  refused with no partial change.
- **Timeout** — a slow or unreachable dependency gives a bounded wait and a
  clear error, not a hang.
- **Retry** — a retried call does not apply its effect twice.
- **Idempotency** — the same request twice leaves the same state as once.
- **Concurrency** — two overlapping operations on one resource: no lost
  update, no duplicate.
- **Partial-failure recovery** — a failure midway leaves consistent state, or
  the documented recovery restores it.

Timeout, concurrency and partial-failure probes run only against the isolated
target from "Choosing the surface".

### 2xx is not completion

An HTTP 2xx, exit code 0 or a "done" log line is the program's claim, not
evidence. A row passes only when its durable effect is read back and matches
the expectation. For accepted-for-later answers (202, a job id, "queued"), poll
the effect with a bounded wait; still absent at the bound is `inconclusive`.

### Running a probe

Run each probe as one command and keep its evidence: the exact command, the
exit code, the stdout and stderr lines that matter, and the read-back, with
secrets redacted as the probe rules require. On this surface that transcript is
the evidence an issue needs; no screenshot is required. Replay a failure once
from the same starting state before recording it. When the skill fixes bugs,
the re-test of a fix reruns the row's exact command and read-back.

Each row ends with one outcome:

- `pass` — the effect was read back and matches the expectation.
- `fail` — the outcome contradicts the expectation; record expected and observed.
- `blocked` — a prerequisite is missing (no isolated target, a credential, a
  dependency that will not start); name it.
- `not run` — deliberately skipped (quick mode, out of scope); say why.
- `inconclusive` — it ran, but the evidence cannot decide.

A failed row is an issue, category Functional, graded by the severity
definitions in the Health Score Rubric. The functional surface gets no health
score, and `blocked`, `not run` and `inconclusive` never count as passes.

### Functional report

Write `$REPORT_DIR/functional-report.md` from
`${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/{SKILL_NAME}}/../qa/templates/functional-report-template.md`.
Add to `$REPORT_DIR/baseline.json` a `"surface"` field (`functional` or
`mixed`) and a `rows` array of `id`, `behavior`, `command` and `outcome`; a
functional-only baseline has no `healthScore`. On a mixed surface the browser
part keeps its own report and score, and the rows never feed that score.
