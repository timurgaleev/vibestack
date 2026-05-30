---
name: ios-sync
description: Regenerate the iOS debug bridge against the latest upstream vibestack templates.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
triggers:
  - resync the ios debug bridge
  - regenerate ios accessors
  - update the vibestack ios instrumentation
---


## When to invoke this skill

Updates StateServer.swift, DebugOverlay.swift, Package.swift,
and the typed @Observable state accessors. Use after you upgrade vibestack
or add new ViewModels/properties that need accessor coverage.
Use when asked to "resync the iOS debug bridge", "regenerate iOS
accessors", or "update the vibestack iOS instrumentation".

Voice triggers (speech-to-text aliases): "resync the iOS debug bridge", "regenerate iOS accessors", "update the vibestack iOS instrumentation".

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
  Full walkthrough: `docs/howto-ios-testing.md`. Tailscale ACL example:
  `ios-qa/docs/tailscale-acl-example.md`.

## Phase 1: Detect installed version

1. Read `<app>/DebugBridgeGenerated/.vibe-version` (written by /ios-qa
   during install). If missing, treat the install as "unknown old version".
2. Read upstream version from `$VIBESTACK_HOME/ios-qa/.vibe-version` (or the
   value baked into the installed vibestack binary).
3. If versions match AND no new `@Observable` classes were added, exit
   early with "already up to date".

## Phase 2: Regenerate codegen output

Run `vibe-ios-qa-regen` (or the underlying SwiftPM tool directly):

```bash
swift run --package-path "$VIBESTACK_HOME/ios-qa/scripts/gen-accessors-tool" \
  gen-accessors --input "$APP_SOURCE_DIR" --output "$APP_SOURCE_DIR/DebugBridgeGenerated"
```

The composite-hash cache key handles whether anything actually needs
regenerating; if Swift version, generator git rev, lockfile, source content,
and platform triple all match the cache, this is a ~50ms no-op.

## Phase 3: Update templated Swift files in place

For each file that comes from `ios-qa/templates/*.swift.template`:

1. Read the current installed file at
   `<app>/DebugBridgeGenerated/<Name>.swift`.
2. Read the upstream template at
   `$VIBESTACK_HOME/ios-qa/templates/<Name>.swift.template`.
3. If the installed file has a `// VIBESTACK-EDIT-LINE` marker, fold the user's
   edits forward.
4. Otherwise, replace the file outright with the new template (after
   AskUserQuestion if the diff is non-trivial).

## Phase 4: Verify

1. `swift build` succeeds against the app's package.
2. `xcodebuild -scheme <SchemeName>` succeeds.
3. Re-launch the app on the device; daemon connects + rotates token.
4. `GET /state/snapshot` returns the new accessor schema hash.

## Failure modes

| Symptom | Action |
|---|---|
| Swift compile fails after regen | Revert via `git restore` + AskUserQuestion: surface the compile error |
| Schema hash unchanged after adding new @Observable | The new class isn't marked `@Snapshotable` — the codegen excludes it correctly. If the user wanted it snapshotted, add the wrapper. |
| `--input` source dir contains test fixtures | gen-accessors scans the input dir recursively; exclude test/ via `--exclude` |

{{include lib/snippets/askuserquestion-split.md}}

{{include lib/snippets/capture-learnings.md}}
