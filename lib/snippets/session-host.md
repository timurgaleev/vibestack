## Session & host detection (run at skill start)

Detect the host so interaction adapts to it. This needs no extra tooling — it
reads environment variables only.

```bash
# Session kind: headless (eval / CI / no human) vs interactive. Best-effort.
_SESSION_KIND="interactive"
{ [ -n "${VIBESTACK_HEADLESS:-}" ] || [ -n "${CI:-}" ]; } && _SESSION_KIND="headless"
echo "SESSION_KIND: $_SESSION_KIND"

# Conductor host: its AskUserQuestion is unreliable (native disabled, MCP
# variant flaky), so render decisions as prose instead of calling the tool.
# Gated on !headless so an eval/CI run INSIDE Conductor still blocks rather
# than printing a prose decision to nobody.
if [ "$_SESSION_KIND" != "headless" ] && { [ -n "${CONDUCTOR_WORKSPACE_PATH:-}" ] || [ -n "${CONDUCTOR_PORT:-}" ]; }; then
  echo "CONDUCTOR_SESSION: true"
fi

# Repo mode: solo (one committer) vs collaborative. Cheap heuristic from git
# history; consumed by skills that handle issues outside the current branch.
_AUTHORS=$(git shortlog -sn --all 2>/dev/null | wc -l | tr -d ' ')
if [ "${_AUTHORS:-1}" -le 1 ] 2>/dev/null; then REPO_MODE="solo"; else REPO_MODE="collaborative"; fi
echo "REPO_MODE: $REPO_MODE"

# Config-driven behavior flags (all via vibe-config; safe defaults).
_VC=~/.vibestack/bin/vibe-config
echo "PROACTIVE: $("$_VC" get proactive 2>/dev/null || echo true)"
_EXPLAIN=$("$_VC" get explain_level 2>/dev/null || echo default); [ "$_EXPLAIN" = terse ] || _EXPLAIN=default; echo "EXPLAIN_LEVEL: $_EXPLAIN"
echo "CHECKPOINT_MODE: $("$_VC" get checkpoint_mode 2>/dev/null || echo explicit)"
echo "CHECKPOINT_PUSH: $("$_VC" get checkpoint_push 2>/dev/null || echo false)"
echo "QUESTION_TUNING: $("$_VC" get question_tuning 2>/dev/null || echo false)"
# Throttled best-effort update nag (once/day, never blocks).
~/.vibestack/bin/vibe-update-check 2>/dev/null || true
echo "MODEL_OVERLAY: ${VIBE_MODEL_OVERLAY:-claude}"
```

`EXPLAIN_LEVEL: terse` (or a "terse / no-explanations" request in the user's
message) means skip optional explanatory prose — lead with the result.
`PROACTIVE: false` means don't auto-invoke or proactively suggest skills; ask
first. These are soft directives the skill body reads.

**If `CONDUCTOR_SESSION: true`** — do NOT call AskUserQuestion. Render every
decision as a prose brief instead: a labeled question, each option with a
one-line tradeoff, a `Recommendation: <choice> because <reason>` line, and
"reply with a letter." A destructive or irreversible confirmation (delete,
force-push, drop, overwrite) demands an explicit typed answer, never a bare
letter.

**If `SESSION_KIND: headless`** — there is no human to answer AskUserQuestion.
For a genuine blocking decision, STOP and report what you need rather than
guessing. For a non-blocking choice, take the recommended option and note that
you auto-picked it.
