---
name: ios-fix
description: Autonomous iOS bug fixer.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
triggers:
  - fix this ios bug
  - patch the iphone app
  - auto-fix the ios issue
---


## When to invoke this skill

Takes a bug found by /ios-qa, reads the source,
writes the fix, rebuilds, redeploys, and verifies the fix on the real
device. Closes the loop: find bug → fix bug → confirm fix — zero human
intervention. Captures the pre-bug state snapshot as a regression test
fixture, so the bug can never recur silently.
Use when /ios-qa reports a bug and you want it fixed automatically, or
when asked to "fix this iOS bug", "patch the iPhone app", or "auto-fix
the iOS issue".

Voice triggers (speech-to-text aliases): "fix the iOS bug", "patch the iPhone app", "auto-fix the iOS issue".

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

## iOS QA daemon — setup

This skill drives a real iPhone through the Mac-side iOS-QA daemon
(`vibe-ios-qa-daemon`, plus the `vibe-ios-qa-mint` tailnet grant CLI) and a
`DebugBridge` Swift package embedded in the app under test. vibestack ships all
of it: the daemon under `ios-qa/daemon/` (Bun), the bridge generated from
`ios-qa/templates/` via `ios-qa/scripts/gen-accessors`. Resolve the launcher and
check readiness first:

```bash
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
D=""
[ -n "$_ROOT" ] && [ -x "$_ROOT/skills/ios-qa/bin/vibe-ios-qa-daemon" ] && D="$_ROOT/skills/ios-qa/bin/vibe-ios-qa-daemon"
[ -z "$D" ] && [ -x "$HOME/.claude/skills/ios-qa/bin/vibe-ios-qa-daemon" ] && D="$HOME/.claude/skills/ios-qa/bin/vibe-ios-qa-daemon"
if [ -n "$D" ] && command -v bun >/dev/null 2>&1; then echo "READY: $D"; else echo "NEEDS_SETUP"; fi
```

If `NEEDS_SETUP`: tell the user what's missing and stop — do NOT fabricate device
interactions, taps, or screenshots. Requirements:
- **Bun** on PATH (https://bun.sh) — the daemon runtime.
- A paired **iPhone over USB** (and Tailscale for the optional `--tailnet` remote path).
- The **`DebugBridge` Swift package** added to the app under test, DEBUG-only:
  generate the typed accessors with `ios-qa/scripts/gen-accessors`, add the
  emitted `DebugBridge` package, and paste the wiring from
  `ios-qa/templates/DebugBridgeWiring.swift.template` into your `@main` App.
  Full walkthrough + Tailscale ACL example under `ios-qa/docs/`.

## Iron Law

**NO FIX WITHOUT A REPRODUCING SNAPSHOT.** Before editing any Swift source,
the agent MUST capture a `GET /state/snapshot` that reproduces the bug.
That snapshot becomes a regression test fixture (`test/fixtures/ios-fix/`).
A fix that lands without a reproducing snapshot is a fix you'll be re-fixing
in three months.

## Phase 1: Reproduce the bug

1. Read the `/ios-qa` finding (bug description, screenshot, suspected
   accessibility-tree node).
2. Bring the device into the bug state via `POST /tap`, `/swipe`, `/type`,
   or `POST /state/<key>` (snapshot-eligible fields only).
3. Capture `GET /state/snapshot` → write to
   `test/fixtures/ios-fix/<bug-slug>-pre.json`.
4. Capture `GET /screenshot` → write to
   `test/fixtures/ios-fix/<bug-slug>-pre.png`.
5. Persist a one-line description of what's wrong + expected behavior.

## Phase 2: Locate root cause

Per `/investigate`'s Iron Law: no fix without root cause. The agent reads the
Swift source, traces from the buggy screen back to the view model, the data
flow, and the state mutation. Identify the smallest change that fixes the
behavior.

Use AskUserQuestion if there are multiple plausible root causes — let the
user pick the one to fix.

## Phase 3: Apply fix

1. Edit Swift source. Keep the diff minimal.
2. Rebuild: `xcodebuild -scheme <SchemeName>
   -destination 'platform=iOS,id=<UDID>' build install`.
3. Daemon detects the rebuild and reconnects the StateServer tunnel.
4. Re-deploy. The same boot-token rotation flow runs.

## Phase 4: Verify

1. `POST /state/restore` with the pre-bug snapshot → reproduces the state.
2. Take a fresh screenshot. Compare against
   `test/fixtures/ios-fix/<bug-slug>-pre.png`.
3. If the bug visibly persists, the fix didn't work — revert and try again
   (max 3 iterations before escalating to the user).
4. If the bug is gone, capture `<bug-slug>-post.png` for the regression test.

## Phase 5: Add regression test

Write a test in `test/fixtures/ios-fix/<bug-slug>.test.ts` that:

1. Loads the pre-bug snapshot.
2. Restores it via `POST /state/restore`.
3. Asserts the post-fix behavior on a real device (gated
   `VIBESTACK_HAS_IOS_DEVICE=1`, periodic tier).

Commit the snapshot fixture + test file alongside the fix.

## Failure modes

| Symptom | Action |
|---|---|
| 3 iterations, bug still present | STOP, report to user with current best hypothesis |
| `409 schema_mismatch` on /state/restore after rebuild | Re-codegen accessors (`swift run gen-accessors`), re-snapshot |
| Device disconnects mid-fix | Daemon auto-reconnects; resume from Phase 4 |
| Build fails | Revert Swift edits; investigate compile error before re-applying fix |

{{include lib/snippets/askuserquestion-split.md}}

{{include lib/snippets/capture-learnings.md}}
