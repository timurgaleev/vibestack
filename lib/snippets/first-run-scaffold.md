On the first-ever skill run in a project, offer one concrete next move — never a wall of options. Detect the project bucket, map it to a single suggestion, then continue with whatever the user actually asked. On a returning session, nudge the `plan → review → ship` loop once. Never fire in headless/eval runs, and never interrupt an explicit command.

```bash
# Each fenced block runs in its own shell — re-derive SLUG here so the state
# file is keyed per project, not the shared `unknown` bucket.
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_FRS_STATE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/.first-run-seen"
if [ ! -f "$_FRS_STATE" ] && [ -z "${CI:-}" ]; then
  _BUCKET=$(~/.vibestack/bin/vibe-first-task-detect 2>/dev/null)
  mkdir -p "$(dirname "$_FRS_STATE")" 2>/dev/null && : > "$_FRS_STATE" 2>/dev/null || true
  echo "FIRST_RUN_BUCKET: ${_BUCKET:-none}"
fi
```

Map the emitted `FIRST_RUN_BUCKET` token to one short first-skill suggestion, shown once before you continue:

| Bucket | One-line suggestion |
|--------|---------------------|
| `greenfield` / `nongit` | Empty repo — shape the idea first: try `/office-hours` or `/spec`. |
| `code_node` / `code_python` / `code_rust` / `code_go` / `code_ruby` / `code_ios` | There's code here — verify it works: `/qa`, or `/investigate` if something's broken. |
| `branch_ahead` | Unshipped work on this branch — `/review` then `/ship`. |
| `dirty_default` | Uncommitted changes — `/review`, then commit with `/ship`. |
| `clean_default` | Clean tree with history — pick a target: `/plan-eng-review` for new work, `/health` for a checkup. |
| `none` (no token) | Show no scaffold — continue silently. |

Keep it to a single line. The suggestion is a nudge, not a gate: proceed with the user's request immediately after.
