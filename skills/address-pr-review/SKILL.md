---
name: address-pr-review
description: |
  Work a pull request's open review threads and failing CI checks to a close: read each unresolved thread, fix or explain, run the tests, commit and push, then reply on every thread and resolve the ones that were addressed. Use after a PR exists on the current branch and reviewers or CI have come back with something.
triggers:
  - address pr review
  - address review comments
  - fix review comments
  - resolve review threads
  - ci is failing on the pr
  - iterate on pr
allowed-tools:
  - Bash
  - Read
  - Edit
  - Grep
  - AskUserQuestion
---

## When to invoke

Use when: "address the review", "fix the review comments", "resolve the threads", "CI is red on the PR", "iterate on the PR", or when a shipping flow hands back a PR that has unresolved threads or failing checks.

## Preamble

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.vibestack/bin/vibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## User-invocable
When the user types `/address-pr-review`, run this skill.

---

## Step 1: Confirm the branch

Never trust the branch name from earlier in the conversation. Ask git:

```bash
git branch --show-current
git status --short
```

If the branch is the default branch (`main`, `master`), stop: there is no PR to
address from there. Say which branch you are on and ask the user to check out
the feature branch.

If the working tree is dirty, list the dirty files before doing anything, and
keep that list. Step 5 stages only the files this round actually edited, so the
list is how you tell your own edits from work that was already in the tree.

---

## Step 2: Collect what is open

Run both collectors. They read the PR from the current branch on their own.

```bash
bash "${CLAUDE_SKILL_DIR}/bin/pr-threads.sh"
bash "${CLAUDE_SKILL_DIR}/bin/pr-ci-failures.sh"
```

`pr-threads.sh` prints a JSON array of unresolved review threads. Each thread
carries `id`, `path`, `line`, `isOutdated`, and its comments with `author`,
`body`, and `url`. The array is the whole list — the script pages through every
thread, so a long review is not silently cut short. Exit 2 means there is no PR
for this branch (stop and say so; `/ship` is the skill that opens one), or that
a page of threads could not be fetched. On that second case nothing is printed
at all: treat it as unknown, not as zero threads, and re-run.

`pr-ci-failures.sh` prints one block per failing check with a trimmed log
excerpt (exit 1), or a status line on exit 0. Report each distinctly — they are
different findings:

- `All checks passed.` — CI ran and is green.
- `No failing checks; N still pending.` — nothing red yet, N jobs unfinished.
  Note it, proceed with the threads, and re-run the script before Step 4 to see
  whether the pending ones landed.
- `No failing checks; N cancelled.` (or `N cancelled, M still pending.`) — one
  or more checks were stopped before they finished. A cancelled check is not a
  pass. The script lists the names under a `CANCELLED CHECKS:` heading; re-run
  them with `gh run rerun <run-id>` or say why they were cancelled.
- `This PR has no checks yet.` — the PR has no checks at all. That is not a
  pass. A workflow may be unconfigured, or not triggered yet. Say so in those
  words and do not record it as green.

A `CANCELLED CHECKS:` block can also appear above the failing checks; carry both
into the report.

Exit 2 means no PR, or that `gh` could not answer at all — an auth, network, or
API error, printed with gh's own message. That is not a green build either: fix
the gh problem and re-run before judging CI.

If the thread array is empty and CI reports `All checks passed.`, stop here.
Report:

```
Nothing to address on <branch>: 0 unresolved threads, all checks passed.
```

If the thread array is empty but CI reported no checks or pending checks, say
that instead of claiming a pass.

Otherwise write down the count of threads and failing checks. That list is the
work; every item on it gets a line in the final report.

---

## Step 3: Decide each item

Work the threads first, then CI. Do not batch decisions — read one, decide,
move to the next.

**For each review thread:**

1. Read the whole thread, not only the last comment. The first comment says
   what the reviewer saw; later ones may narrow or withdraw it.
2. Open the file at `path:line` with Read. If `isOutdated` is true, the line
   moved since the comment was written; find the current location with Grep
   before judging whether the concern still holds.
3. Decide one of:
   - **fix** — the reviewer is right. Make the change with Edit. Keep the
     change to what the thread asks; a thread about a null check is not a
     licence to refactor the function.
   - **no-change** — the concern does not apply, is already handled, or is a
     matter of taste the author decided differently. Write down the reason in
     one sentence. That sentence becomes the reply in Step 6.
4. Outdated threads still get a decision and a reply. "Outdated" means the diff
   moved, not that the reviewer was answered.
5. If a thread asks a question rather than requesting a change, the decision is
   **no-change** with the answer as the reason.

If a thread is genuinely ambiguous — two readings that lead to different code —
do not guess. Ask the user which one, then continue.

**For each failing CI check:**

1. Read the excerpt. The first `FAIL`/`ERROR` line names the test or step; the
   lines after it usually carry the assertion or the compiler message.
2. Reproduce locally where possible: run the single failing test or the lint
   command the job ran. A failure you cannot reproduce needs the full log
   (`gh run view --job <id> --log`) before you change anything.
3. Fix the code. Fix the test only when the test asserts something the change
   intentionally altered; say so in the commit message.
4. A flaky or infrastructure failure (runner lost, network timeout) is not a
   code fix. Re-run it with `gh run rerun <run-id> --failed` and record that in
   the report instead of editing code.

Give every item a severity. It goes in the report table, so the reviewer can see
what you treated as a bug and what you treated as taste:

- **blocking** — a failing check, or a thread that points at a real bug.
  Must be fixed before the PR moves.
- **should-fix** — a correctness or clarity point that is right but not a bug.
  Fix it unless the user says otherwise.
- **discuss** — a design disagreement or a question. Reply with the reasoning;
  leave the thread open for the reviewer.

---

## Step 4: Run the project's tests

Find the test command the project uses. Order of preference: a `## Health Stack`
section in CLAUDE.md, then `package.json` scripts, then `pyproject.toml`,
`Cargo.toml`, `go.mod`, then `test/*.sh` runners in the repo root.

```bash
grep -A8 '^## Health Stack' CLAUDE.md 2>/dev/null | grep -i 'test:' || true
[ -f package.json ] && grep -E '"test"' package.json || true
ls test/*.sh 2>/dev/null || true
```

Run the full suite, not only the tests you touched. Capture the tail of the
output. If it fails, go back to Step 3 for the new failure — do not commit a red
suite. If the project has no test command, say so in the report and run
whatever lint or type check it does have.

If CI still had pending checks in Step 2, re-run `pr-ci-failures.sh` now.

---

## Step 5: Commit and push

This skill runs inside a shipping flow, so committing here is expected. Before
you do, tell the user exactly what is about to leave the machine:

```bash
git status --short
git diff --stat
```

Write down the files your own edits in Step 3 touched. Compare that list against
what `git status --short` shows. If the tree carries modified or untracked files
that are not on your list — the dirty files from Step 1, or anything else — say
so by name and stop. Ask the user whether to stash them, commit them separately,
or continue without them. Do not decide that on your own.

State in plain words: which files, which threads and checks they answer, and the
commit message you intend to use. Then stage those files by name — never
`git add -A`, `git add .`, or `git commit -a`, all of which sweep unrelated work
into the commit:

```bash
git add <file-you-edited> <another-file-you-edited>
git status --short          # confirm the staged set is exactly your list
git commit -m "<type>: <what the review asked for, in one line>"
```

One commit for the whole round is the default. Split into several only when the
review covered clearly separate concerns and a reviewer will want to read them
apart. Never amend or force-push — the reviewer is reading the branch history.

The push is a separate decision. Show the commit and ask the user to confirm it
before it goes to the remote — AskUserQuestion, with the branch and the one-line
message in the prompt:

```bash
git log -1 --stat
# confirmed → push
git push
```

If the user declines, say the commit is local and unpushed, and stop before Step
6. A reply saying a thread is fixed points at a diff the reviewer cannot see
until the branch is pushed, so the replies wait for the push. Report the round
as committed but not pushed.

If there is nothing to commit (every thread was a no-change), skip the commit
and say so; Step 6 still runs.

---

## Step 6: Reply on every thread

Use the reply script once per thread. One invocation posts the reply and, with
`--resolve`, marks the thread resolved:

```bash
bash "${CLAUDE_SKILL_DIR}/bin/pr-thread-reply.sh" "<thread_id>" "<reply text>" --resolve
bash "${CLAUDE_SKILL_DIR}/bin/pr-thread-reply.sh" "<thread_id>" "<reply text>"
```

It prints the URL of the new comment; keep it for the report.

- **fixed** → one or two sentences saying what changed, with `--resolve`.
  Example: `Added the null guard and a test for the empty case.`
- **no-change** → the reason from Step 3, without `--resolve`. The reviewer
  decides whether that closes it. Example: `This path is only reached after
  validate() has run, so the input is already non-empty; leaving as is.`
- **question answered** → the answer, without `--resolve`.

The reply and the resolve are two API mutations, so `--resolve` has a
partial-success state: the reply lands, the resolve fails, and the script exits
1 after printing `reply posted but thread did not resolve` on stderr with the
comment URL still on stdout. The thread is then answered but open — not a failed
reply.

The retry is the identical command. Before posting, the script reads the
thread's existing comments; when one already carries exactly this body it reuses
that comment instead of posting a second copy and goes straight to the resolve.
So re-running is safe, but only with the same reply text — rewording it makes a
new comment.

Never resolve a thread you did not act on. Never edit or delete a reviewer's
comment. If the script exits non-zero, print its stderr and keep going with the
remaining threads. Read the stderr before recording the outcome: a thread that
printed `reply posted but thread did not resolve` goes in the report as
replied-but-unresolved with its URL, and one that failed with no URL goes in as
a failed reply.

---

## Output

```
PR REVIEW ROUND: <owner/repo>#<number> (<branch>)
================================================

THREADS (<n> unresolved at start)

thread         | file:line              | severity   | action    | reply
-------------- | ---------------------- | ---------- | --------- | ---------------------
<author> #1    | src/auth.ts:42         | blocking   | fixed     | <comment url>
<author> #2    | src/auth.ts:88 (moved) | discuss    | no-change | <comment url>
<bot> #3       | test/auth.test.ts:10   | should-fix | fixed     | <comment url>

Resolved: <k>   Left open: <n-k>   Reply failed: <m>

CI

check                | before   | after
-------------------- | -------- | --------
test (ubuntu-latest) | FAILURE  | fixed — <one line on the cause>
lint                 | SUCCESS  | unchanged
build                | FAILURE  | re-run (runner lost, not a code failure)

Tests: <command> — <pass/fail counts or exit code>
Commit: <sha> "<message>"  pushed to origin/<branch>
        (or: committed, push declined — the branch is local only)
Staged:  <the files named in Step 5>
Left in the working tree: <files that were dirty and not part of this round>

Open items for the reviewer: <list threads left open, each with its severity and
the reason it is open>
```

If nothing was open, the whole output is the one-line "Nothing to address"
message from Step 2.

---

## Important Rules

1. **Branch from git, not from memory.** Step 1 runs `git branch --show-current` every time. Stale context ships fixes to the wrong PR.
2. **Every open thread gets a reply.** Fixed, not changed, or answered — but never silently skipped, and never resolved without being addressed.
3. **Bots are reviewers.** Comments from Greptile, Codex, Copilot, or any other automated reviewer get the same read-decide-reply treatment as a human's.
4. **Never rewrite reviewer text.** Reply in a new comment; do not edit, hide, or delete what the reviewer wrote.
5. **Replies are short.** One or two sentences. The diff carries the detail; the reply points at it.
6. **Fix the cause, not the check.** Skipping a test, loosening an assertion, or adding `continue-on-error` to make CI green is out of scope unless the user asks for it by name.
7. **Green before push.** The project's test suite runs and passes before the commit. A red suite goes back to Step 3.
8. **Stage by name.** Only the files this round edited go into the commit, named one by one. `git add -A`, `git add .`, and `git commit -a` are out — they publish whatever else was in the tree. Unrelated changes stop Step 5 and go to the user as a question.
9. **The push is confirmed, not assumed.** The commit is shown and the user says yes before anything reaches the remote. A declined push ends the round with a local commit.
10. **Commit and push are in scope; nothing else on the remote is.** No force-push, no amend, no branch deletion, no merge. The PR itself is untouched except for thread replies and resolutions — no title, body, label, or reviewer changes.
11. **Ambiguity stops the loop.** A thread with two reasonable readings gets a question to the user, not a guess.

{{include lib/snippets/capture-learnings.md}}
