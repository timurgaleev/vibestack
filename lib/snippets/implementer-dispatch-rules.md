**Rules for the implementing agent.**

1. Every test you add or change carries a value card from the test value bar, with `no_claim` whenever green leaves something unproven.
2. Real code and its real tests land in one change: no stub that only satisfies a test, no tests deferred to a follow-up.
3. Any edit to a test, validator, CI step, timeout, threshold, snapshot or suppression pragma is reported first, on its own line, with its reason.
4. Every command you cite comes with the result you observed (exit code, pass/fail counts); never silence stderr on a check you report.
5. Your report is a claim, not a verdict: the parent re-runs the checks before anything counts as done.
