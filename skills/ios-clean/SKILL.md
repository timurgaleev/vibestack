---
name: ios-clean
description: "Remove the DebugBridge SPM package and all #if DEBUG wiring from an iOS app."
allowed-tools:
  - Bash
  - Read
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
triggers:
  - clean the ios debug bridge
  - remove debugbridge
  - strip the vibestack ios instrumentation
---


## When to invoke this skill

Cleans up StateServer, DebugOverlay, accessor codegen output, and
app-side hooks installed by /ios-qa. This is a convenience wrapper —
the structural Release-build guard (Package.swift conditional + CI
swift build -c release check) is the safety-critical path.
Use when asked to "clean the iOS debug bridge", "remove DebugBridge",
or "strip the vibestack iOS instrumentation".

Voice triggers (speech-to-text aliases): "clean the iOS debug bridge", "remove DebugBridge", "strip the vibestack iOS instrumentation".

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

## What it removes

Each item is reverted only after AskUserQuestion confirmation:

1. The `DebugBridge` SPM target from `Package.swift`.
2. The `#if DEBUG` block in the app's `@main` entry that calls
   `DebugBridgeManager.shared.start()`.
3. Any `@Snapshotable` property wrappers on the canonical app state struct
   (the codegen-detection markers — the wrapper file lives inside
   DebugBridge so removing the SPM dep removes the wrapper too).
4. Generated `StateAccessor.swift` files anywhere under the app source.
5. The `vibe-ios-qa.token` file under `NSTemporaryDirectory()` on the
   device (best-effort — only works if device is connected when /ios-clean
   runs).

## What it does NOT touch

- App business logic, view models, view code.
- Anything outside `#if DEBUG` blocks.
- Other test or QA infrastructure.

## Phase 1: Inventory

1. Glob for `import DebugBridge` across the app source.
2. Glob for `#if DEBUG ... DebugBridgeManager` blocks.
3. Glob for `// Auto-generated state accessor` headers in
   `StateAccessor.swift` files.
4. Parse `Package.swift` for the DebugBridge dependency entry.
5. Show the user what's about to be removed (file list + line counts).
   AskUserQuestion: proceed, dry-run, or abort.

## Phase 2: Remove

For each item the user approved:

1. Use Edit tool to strip the import + the `#if DEBUG` block (keep the
   surrounding code intact).
2. Use Edit tool to remove the `.package(url:...DebugBridge...)` entry
   from `Package.swift` and any `targets` referencing `"DebugBridge"`.
3. Delete generated `StateAccessor.swift` files.
4. Run `xcodebuild -scheme <SchemeName> -destination 'platform=iOS,id=<UDID>'
   build install -configuration Release` to verify Release builds without
   the bridge. If it fails on a missing DebugBridge symbol, the removal
   was incomplete — STOP and report.

## Phase 3: Verify

1. `! grep -r "DebugBridge" <app-source-dir>` (no matches).
2. `! grep -r "@Snapshotable" <app-source-dir>` (no matches).
3. `swift build -c release` succeeds.
4. `nm -j` on the built binary doesn't show DebugBridge symbols.

Report the cleanup result + a one-line summary of what got removed.

## Reversibility

Every Edit + delete is a git operation; the user can `git restore` to undo.
This skill never force-pushes, never amends, never deletes the SPM cache —
those are user choices.

{{include lib/snippets/askuserquestion-split.md}}

{{include lib/snippets/capture-learnings.md}}
