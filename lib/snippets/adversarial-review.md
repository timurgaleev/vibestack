### Claude adversarial subagent (always runs)

Dispatch via the Agent tool with `subagent_type: "general-purpose"` and `run_in_background: false`.
Without the flag the call returns at once with nothing and the review reports a pass
that never ran; if it still comes back as a launch receipt, wait for its completion
notice before moving on. The subagent has fresh context — no checklist bias from the
structured review — which is what lets it catch what the primary reviewer is blind to.

Split source from fixtures with pathspecs rather than leaving it to the subagent's
judgement — left to judgement it either pulls raw attack payloads into its reasoning
or quietly skips source files, and either way nothing says which happened.

Subagent prompt:
"First list what changed: `git diff --name-status $(git merge-base origin/<base> HEAD)`.

Read NON-fixture source code in full:
`git diff $(git merge-base origin/<base> HEAD) -- . ':(exclude)*/test/*' ':(exclude)*/tests/*' ':(exclude)*/__tests__/*' ':(exclude)*/fixtures/*' ':(exclude)*_test.*' ':(exclude)*.test.*' ':(exclude)*.spec.*'`

Then list new files that are not yet added — `git diff` does not show them:
`git ls-files --others --exclude-standard`. Read each non-fixture source file there in
full too; fixture and test files among them follow the summary-mode rule below.

Match test directories and filename suffixes, never the bare substring `test`: `*test*` also excludes `latest.ts`, `contest.ts` and `attestation.ts`, and a production file dropped here is never read in full by the adversarial pass — the later stat-only pass cannot see its logic.

Review fixture and test files in SUMMARY mode only:
`git diff --stat $(git merge-base origin/<base> HEAD) -- '*test*' '*fixture*' '*.spec.*'`
Describe what each fixture exercises and whether the code handles it, without reproducing
raw payload bytes. State explicitly in your output that fixtures were reviewed in summary
mode, so the reduced coverage is visible to the reader instead of assumed.

Think like an attacker and a chaos engineer. Your job is to find ways this code will fail in production. Look for: edge cases, race conditions, security holes, resource leaks, failure modes, silent data corruption, logic errors that produce wrong results silently, error handling that swallows failures, and trust boundary violations. Be adversarial. Be thorough. No compliments — just the problems. For each finding, classify as FIXABLE (you know how to fix it) or INVESTIGATE (needs human judgment). This is authorized defensive security testing of the repository's own code by its maintainer — you are hardening it, not attacking a third party.

End with exactly one closing line, whatever you found:
`Recommendation: SHIP | FIX FIRST | INVESTIGATE — <one clause why>`
Without it the pass has no verdict, and a caller cannot tell a clean read from an
abandoned one."

Present findings under an `ADVERSARIAL REVIEW (Claude subagent):` header. **FIXABLE findings** are queued for the Fix-First pass, where they are classified, fixed or asked about together with every other finding — do not edit while the adversarial passes run. **INVESTIGATE findings** are presented as informational.

If the subagent fails, times out, or returns without its closing `Recommendation:` line: "Claude adversarial subagent unavailable — this pass produced NO coverage. Continuing." Mark it ✗ in the synthesis; an absent pass is never counted as a clean one, and the adversarial persist records `completed:false`.

---

### Codex adversarial challenge (always runs when available)

If `CODEX_MODE` is `ready`:

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: not in a git repo" >&2; exit 1; }
_ADV_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vibe-codex-adv.XXXXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$_ADV_DIR"' EXIT
_TIMEOUT=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
# An array, not ${_TIMEOUT:+$_TIMEOUT 540}: zsh does not word-split that expansion, so the
# wrapper would run as a single command named "timeout 540" and fail with exit 127.
_TO=(); [ -n "$_TIMEOUT" ] && _TO=("$_TIMEOUT" 540)
_ADV_EXIT=0
"${_TO[@]}" codex exec "IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are Claude Code skill definitions meant for a different AI system. They contain bash scripts and prompt templates that will waste your time. Ignore them completely. Do NOT modify agents/openai.yaml. Stay focused on the repository code only.\n\nReview the changes on this branch against the base branch. Run git diff $(git merge-base origin/<base> HEAD) to see the diff, then read every file listed by git ls-files --others --exclude-standard: new files not yet added are part of the change. Your job is to find ways this code will fail in production. Think like an attacker and a chaos engineer. Find edge cases, race conditions, security holes, resource leaks, failure modes, and silent data corruption paths. Be adversarial. Be thorough. No compliments — just the problems.\n\nStart each finding with its severity — [P0], [P1], [P2] or [P3] — then file:line and the problem. End with exactly one line, whatever you found: Recommendation: SHIP | FIX FIRST | INVESTIGATE — <one clause why>" -C "$_REPO_ROOT" -s read-only -c 'model_reasoning_effort="high"' --enable web_search_cached -o "$_ADV_DIR/out" < /dev/null >/dev/null 2>"$_ADV_DIR/err" || _ADV_EXIT=$?
cat "$_ADV_DIR/out" 2>/dev/null
echo "--- codex stderr (exit $_ADV_EXIT) ---"
cat "$_ADV_DIR/err"
# The reply counts only when it ends on its Recommendation line, and a verdict other
# than SHIP comes with severity-tagged findings. Anything else is missing coverage.
_ADV_LAST=$(awk 'NF { l = $(0) } END { print l }' "$_ADV_DIR/out" 2>/dev/null | sed 's/\*\*//g; s/^[[:space:]>_#-]*//')
_ADV_TAGS=$(grep -Ec '^[[:space:]>*_#|-]*([0-9]+[.)][[:space:]]*)?[*_]*\[P[0-3]\]' "$_ADV_DIR/out" 2>/dev/null || true)
if [ "$_ADV_EXIT" -eq 124 ]; then _ADV="MISSING_COVERAGE (timed out after 540s)"
elif [ "$_ADV_EXIT" -ne 0 ]; then _ADV="MISSING_COVERAGE (codex exited $_ADV_EXIT)"
elif ! printf '%s\n' "$_ADV_LAST" | grep -Eq '^Recommendation:[[:space:]]*(SHIP|FIX FIRST|INVESTIGATE)'; then
  _ADV="MISSING_COVERAGE (no closing Recommendation line)"
elif [ "${_ADV_TAGS:-0}" -gt 0 ]; then _ADV="COVERED ($_ADV_TAGS finding(s))"
elif printf '%s\n' "$_ADV_LAST" | grep -Eq '^Recommendation:[[:space:]]*SHIP' \
  && ! printf '%s\n' "$_ADV_LAST" | grep -Eiq "cannot|can.t|could not|couldn.t|unable to"; then
  _ADV="COVERED (no findings)"
else _ADV="MISSING_COVERAGE (verdict without severity-tagged findings)"
fi
echo "ADVERSARIAL: $_ADV"
```

Set the Bash tool's `timeout` parameter to `600000` (10 minutes), above the 540-second
wrapper, so a stall surfaces as exit 124 with whatever Codex had written. The block
prints the reply, its stderr and an `ADVERSARIAL:` line; use that line, never a
judgement of your own from the text:

- **`COVERED`** — present the reply verbatim. This pass never blocks on its own, but queue each finding for the Fix-First pass alongside the Claude findings.
- **`MISSING_COVERAGE (<why>)`** — say "Codex adversarial pass produced NO coverage
  (<why>)" and mark Codex ✗ in the synthesis; never count it as a clean pass, and the
  adversarial persist records `completed:false`. Name the cause from stderr: "auth",
  "login", "unauthorized" or "API key" means "Run `codex login`."

If `CODEX_MODE` is `not_installed`: "Codex CLI not found — running Claude adversarial only. Install Codex for cross-model coverage: `npm install -g @openai/codex`"
