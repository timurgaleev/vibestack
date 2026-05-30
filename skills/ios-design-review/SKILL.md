---
name: ios-design-review
description: Visual design audit for iOS apps on real hardware.
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - AskUserQuestion
triggers:
  - review the ios design
  - audit the iphone app visuals
  - design qa the ios app
---


## When to invoke this skill

Connects to a real
iPhone via the same StateServer as /ios-qa, screenshots every screen,
evaluates against Apple HIG, DESIGN.md, and design best practices. Scores
each dimension 0-10 with "what would make it a 10" framing — mirrors
/plan-design-review for browser. For plan-stage design review (before
implementation), use /plan-design-review. For live web visual audits, use
/design-review.
Use when asked to "review the iOS design", "audit the iPhone app's
visuals", or "design QA the iOS app".

Voice triggers (speech-to-text aliases): "review the iOS design", "audit the iPhone app's visuals", "design QA the iPhone app".

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

## Connection

Uses the running `vibe-ios-qa-daemon`. If no daemon is running, spawn one
via the same flow as `/ios-qa` (Phase 0-2). Read-only by default — no
mutating calls.

## Dimensions + scoring

For each screen in the app, score 0-10 and explain what would push it to 10:

1. **Typography hierarchy.** Display vs body vs caption sizes consistent
   with Apple HIG. SF Pro at correct dynamic-type scale. Line-height matches
   font size. No 12pt body anywhere.
2. **Spacing rhythm.** 4pt or 8pt grid used consistently. No magic
   17/23/31pt paddings. Safe-area insets respected.
3. **Color hierarchy.** Primary action highest contrast; secondary muted;
   destructive distinct. Dark mode renders correctly. Contrast ratios meet
   WCAG AA for body text (4.5:1) and large text (3:1).
4. **Touch targets.** Every interactive element >= 44x44pt. No "tappable
   text" smaller than 24pt.
5. **Loading + empty + error states.** Each present and intentional. No
   blank screens during async work. Empty states explain what to do next.
6. **Accessibility.** VoiceOver labels on every interactive element.
   Dynamic Type cap at XXL doesn't break layouts. Reduce Motion respected.
   Color-blindness palette tested (deuteranopia is most common).
7. **Animation discipline.** No more than 2 simultaneous animations.
   Duration 200-300ms for UI feedback. Spring damping correct (not bouncy
   for serious flows).
8. **iOS idiom alignment.** Uses native components (`NavigationStack`,
   `List`, `Form`, system sheets) where appropriate. No re-invented
   navigation. No web-style hamburger menus on phone.
9. **Information density.** Per-screen content fits without horizontal
   scroll. Long screens have section anchors. Lists use real iOS list
   patterns (swipe-to-delete, contextual menus).
10. **AI-slop check.** Generic stock layouts, "lorem ipsum" data left in,
    cargo-cult Material Design imported from Android, gradients that smell
    AI-generated.

## Loop

1. `POST /session/acquire` with capability `observe` (read-only).
2. For each major screen (driven from a screen list the user provides, or
   auto-discovered via the accessibility tree):
   - `GET /screenshot`
   - `GET /elements`
   - Apply the 10-dimension rubric.
   - Record findings.
3. Produce a markdown report with screenshots, scores per screen, and a
   "biggest leverage fix" suggestion per dimension.
4. Use AskUserQuestion for any score < 7 — present the issue with
   recommended fix + tradeoff so the user can decide whether to address.

## Output

Write a markdown report to
`~/.vibestack/projects/<slug>/ios-design-review-<date>.md`. Include the
screenshots inline. The CEO/eng review skills can reference this report
when planning UI changes.

## Failure modes

| Symptom | Action |
|---|---|
| `403 capability_insufficient` from /screenshot | Daemon is in tailnet mode and token is below `observe` tier — owner must mint with `--capability observe` |
| Screenshot is black/blank | App may be in foreground but not rendering; AskUserQuestion to confirm the app is in the expected state |
| 10 screens, but ground-truth screen list said 12 | AskUserQuestion: were 2 hidden behind state we haven't triggered? |

{{include lib/snippets/askuserquestion-split.md}}

{{include lib/snippets/capture-learnings.md}}
