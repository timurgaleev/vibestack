# Flaky, intermittent and CI-only failures

Read from `/investigate` Phase 2 when a failure does not happen every run, or happens only in CI. Everything in the main skill still holds: the `LOOP:` line, ranked hypotheses, one variable per probe, the regression test red before the fix. This file adds what a failure that comes and goes needs on top.

"Flaky" is a symptom, never a cause. The job is the same as for any bug: find the one condition that makes it fail, prove it, remove it.

## 1. Measure the rate on base and on the branch

Run the project's single-file test command for the failing file in a loop, on the branch and on the base, N ≥ 10 times each (20 is a good default; raise it when the rate is low). Same command, same machine, nothing else running. `SETUP` installs the base worktree's dependencies (`true` when there are none); without it every base run fails for the wrong reason.

```bash
CMD='<single-file test command for the failing file, run from the repo root>'
SETUP='<dependency install command for a fresh checkout, or true>'
BASE='<base ref, e.g. origin/main>'
N=20
rate() {
  fails=0
  for _ in $(seq 1 "$N"); do
    (cd "${1}" && sh -c "$CMD") >/dev/null 2>&1 || fails=$((fails+1))
  done
  echo "$fails/$N"
}
WT="$(mktemp -d)/base"
git worktree add --detach "$WT" "$BASE" >/dev/null
(cd "$WT" && sh -c "$SETUP") >/dev/null 2>&1 || { echo "SETUP failed in the base worktree — no base rate"; git worktree remove --force "$WT"; exit 1; }
echo "branch failed/N: $(rate .)"
echo "base   failed/N: $(rate "$WT")"
git worktree remove --force "$WT"
```

Before the loop, run `CMD` once in each tree with its output visible. The failing test must exist on the base (a new or renamed test has no base rate, and a runner that matches nothing exits 0), and the base worktree resolves its own code, not the branch's: no activated branch `.venv`, editable install or `PATH` entry pointing back at the branch checkout. A run that ends with exit 126 or 127, or fails before any test starts, cannot run; fix that first, it is not a failure.

Read the two rates. `0/N` rules out only a rate above 3/N (about 15% at N=20): a 5% flake shows `0/20` one time in three.

- base `0/N`, branch at least 5/20 (or the same ratio at a larger N) — the branch introduced it; the cause is in the diff. A branch count below that against base `0/N` is not yet distinguishable from noise: raise N on both sides until it is.
- both above zero at a similar rate (counts within a few of each other at the same N) — a pre-existing flake; it does not block this branch, and it is still not loosened (section 3).
- both `0/N` locally, red in CI — the difference is the environment: CPU count, parallelism, file-system speed, locale, time zone, clock, network. Diff the CI job's environment against yours the way Phase 2's working example diff does, and reproduce under the CI condition (fewer cores, the CI parallelism flag, the CI container image).

Then date when it started. The last green CI run's `headSha` and the first red one bracket the commits that moved it:

```bash
WF='<workflow file name, e.g. tests.yml>'
BR='<branch the CI runs on, e.g. the base branch>'
gh run list --workflow "$WF" --branch "$BR" --status success --limit 30 --json headSha,createdAt
gh run list --workflow "$WF" --branch "$BR" --status failure --limit 30 --json headSha,createdAt
```

The first failure after the last success is the first moved `headSha`; `git log <last-green-sha>..<first-red-sha>` is the candidate range, and a loop over that range with `git bisect run` (Phase 1's bisection, clean tree first) narrows it when the rate is high enough to trust each step.

## 2. No probe, no cause.

A flake's cause is named only after a probe forces it. Make the suspected condition happen on purpose — inject the delay, pre-pollute the state, pin the order or the seed, hold the lock — and the failure goes to (nearly) `N/N`; take the condition away and it goes back to `0/N`. Record both rates. A cause that has not been forced is still a hypothesis, however plausible the story; say so in the report.

## 3. Never loosen

A longer timeout, a retry, a skip, a quarantine tag or a widened tolerance is a gate relaxation, not a fix. It lowers the chance the test catches a real regression. Never apply one as the fix. If one is still proposed (for example as a stopgap while the real fix lands), state P(fail | regression) before and after in the report: a test that fails 3 times in 10 under a real intermittent regression catches it with probability 0.3 per run; wrapped in three retries it catches it with 0.3 × 0.3 × 0.3 ≈ 0.03. The user decides with those two numbers in front of them.

A CI rerun is allowed only with a named outside cause, quoted from the log: the runner ran out of memory or disk, a package registry or third-party API returned 5xx, the job was cancelled by a newer push. "It passed on retry" is not a cause.

**Timing assertions.** When a test asserts a duration, measure before touching the bound: run it N times and report min/p50/p95/max. Fix the measurement, not the bound — count operations instead of timing them, use a fake or injected clock, compare against a baseline measured in the same run, or assert on p50 over several iterations. Raising the threshold until it passes is loosening.

**Condition-based waiting.** A `sleep` before an assertion is a guess about timing and fails on a slow runner. Replace it with a condition-based wait: poll for the condition itself (the port accepts, the file exists, the message arrived, the row is visible) with a deadline, and on timeout print the last observed state so the failure explains itself.

## 4. Run alone, in the full suite, in random order

The three runs separate the main kinds of flake:

1. **Alone** — the single file in the loop above. Red alone means the cause is inside the file: a race, timing, or randomness.
2. **Full suite** — the project's whole test command, in its usual order. Green alone but red here means another file affects it: go to Order-dependent failures.
3. **Random order** — the runner's shuffle option with a printed seed (`go test -shuffle=on`, `jest --randomize --seed=<n>`, `rspec --order random`, `pytest -p randomly`). A seed that fails is a deterministic repro: put it in the `LOOP:` command.

## Order-dependent failures

The failing test (the victim) is fine; something an earlier file did is still there when it runs.

1. Run the victim alone, then after the earlier files in the order the suite ran them. Alone green and after red confirms the order dependence.
2. Find the polluter: bisect the list of earlier files — run the first half followed by the victim, then the second half, keep the half that turns it red, repeat until one file is left. A file that turns the victim red on its own is the polluter.
3. Name what leaked before changing anything. The usual suspects: an environment variable set and not restored, a changed working directory, a process exit code left set, a module-level singleton or cache, a mock or stub never restored, a listening server or open port, a temp file or directory left behind, home-directory state (config, credentials, a dotfile written under the real or a shared fake `$HOME`), a timer or interval still scheduled, a fake clock never reset. Prove it with a probe: add the leaked state by hand before the victim alone and watch it go red.
4. Fix the polluter: restore what it changed in its own teardown, or scope the change so it cannot outlive the test. Adding a reset to the victim hides the leak from this victim and leaves it for the next one.

## Races

Two actors (threads, processes, requests, workers) touch shared state and the result depends on who goes first.

1. **See the interleaving.** Log each actor's id and a monotonic timestamp at every read and write of the shared state, tagged `[DEBUG-<short>]` like any temporary log. Merge and sort. Wall-clock time can repeat or go backwards; a monotonic clock per actor cannot.
2. **Force it.** Put a test-only hook between the check and the act (a latch, barrier or channel the test controls; compiled out or inert in production) and make the test hold actor A at the hook until actor B has acted. The bad interleaving now happens every run, which is the red the regression test needs.
3. **Test the invariant under load.** Alongside the forced test, start N ≥ 8 concurrent writers against the real code and assert the invariant afterwards: the counter equals the number of increments, no update was lost, no id was issued twice, the file is whole.
4. **Fix with an atomic primitive.** The check and the act become one step: a compare-and-swap or a conditional update (`UPDATE … WHERE version = ?`), a unique constraint with insert-on-conflict handling, an exclusive create (`O_EXCL`) or write-then-atomic-rename for files, a lock held across both the check and the act, or a single writer that owns the state and takes requests from a queue.

A smaller check-then-act window is not a fix. Moving the check closer to the act, adding a sleep, or caching less makes the race rarer and the test greener while the bug stays; the forced-interleaving test still fails against it.

## Flake evidence

Add this block to the DEBUG REPORT, below `Regression proof:`. A field with nothing to say holds `none: <reason>`.

```
Flake evidence:
  Rate:          branch <f>/<N>, base <f>/<N>   (<command>, same machine)
  First moved:   <last green headSha> → <first red headSha> (<dates>)
  Kind:          order-dependent (polluter <file>, leaked <what>) | race (<state>, <actors>) | timing | environment (<difference>) | outside cause (<named, quoted from the log>)
  Probe:         <condition forced> → <f>/<N> with it, <f>/<N> without
  Order runs:    alone <f>/<N>, full suite <f>/<N>, random <seed> <result>
  Gate changes:  none | <change> — P(fail | regression) <before> → <after>
```
