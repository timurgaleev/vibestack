---
name: design-html
description: |
  Turn an approved mockup, plan or description into production-quality, reflowing HTML/CSS.
triggers:
  - build the design
  - code the mockup
  - make design real
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  - AskUserQuestion
---

## When to invoke

Use when: "finalize this design", "turn this into HTML", "build me a page", "implement this design", or after any planning skill.

Proactively suggest when user has approved a design or has a plan ready.

Voice triggers (speech-to-text aliases): "build the design", "code the mockup", "make it real".

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

---

# /design-html: Pretext-Native HTML Engine

You generate production-quality HTML where text actually works correctly. Not CSS
approximations — computed layout via Pretext. Text reflows on resize, heights adjust
to content, cards size themselves, chat bubbles shrinkwrap, editorial spreads flow
around obstacles. If you find yourself faking a layout with fixed heights, magic
numbers, or `line-clamp`, you have left the engine behind and the output is no longer
what this skill promises.

## DESIGN SETUP

```bash
# Bind $D to vibe-design (OpenAI image backend) when a key is configured.
D=${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-design
if [ -x "$D" ] && [ "$("$D" status 2>/dev/null)" = "DESIGN_AVAILABLE" ]; then
  echo "DESIGN_AVAILABLE via $D"
else
  echo "DESIGN_NOT_AVAILABLE"
fi
```

If `DESIGN_NOT_AVAILABLE`: skip visual mockup generation and fall back to text-based design review.

`$D` generates image variants — nothing else. There is no vision extractor here: when
this skill needs to read a mockup, you read it yourself with the Read tool. Never
invent a subcommand; anything other than `status` and `variants` either reports that
it is unsupported or exits with a usage error.

**CRITICAL PATH RULE:** All design artifacts (mockups, comparison boards,
`approved.json`) MUST be saved under `${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/designs/`, NEVER to
`.context/`, `docs/designs/`, `/tmp/`, or any project-local / version-controlled
directory. Design artifacts are USER data, not project files. The finalized HTML is
the exception — that is the deliverable, and it goes wherever the user asks for it.

## UX Principles: How Users Actually Behave

These principles govern how real humans interact with interfaces. They are observed
behavior, not preferences. Apply them before, during, and after every design decision.

### The Three Laws of Usability

1. **Don't make me think.** Every page should be self-evident. If a user stops
   to think "What do I click?" or "What does this mean?", the design has failed.
   Self-evident > self-explanatory > requires explanation.

2. **Clicks don't matter, thinking does.** Three mindless, unambiguous clicks
   beat one click that requires thought. Each step should feel like an obvious
   choice (animal, vegetable, or mineral), not a puzzle.

3. **Omit, then omit again.** Get rid of half the words on each page, then get
   rid of half of what's left. Happy talk (self-congratulatory text) must die.
   Instructions must die. If they need reading, the design has failed.

### How Users Actually Behave

- **Users scan, they don't read.** Design for scanning: visual hierarchy
  (prominence = importance), clearly defined areas, headings and bullet lists,
  highlighted key terms. We're designing billboards going by at 60 mph, not
  product brochures people will study.
- **Users satisfice.** They pick the first reasonable option, not the best.
  Make the right choice the most visible choice.
- **Users muddle through.** They don't figure out how things work. They wing
  it. If they accomplish their goal by accident, they won't seek the "right" way.
  Once they find something that works, no matter how badly, they stick to it.
- **Users don't read instructions.** They dive in. Guidance must be brief,
  timely, and unavoidable, or it won't be seen.

### Billboard Design for Interfaces

- **Use conventions.** Logo top-left, nav top/left, search = magnifying glass.
  Don't innovate on navigation to be clever. Innovate when you KNOW you have a
  better idea, otherwise use conventions. Even across languages and cultures,
  web conventions let people identify the logo, nav, search, and main content.
- **Visual hierarchy is everything.** Related things are visually grouped. Nested
  things are visually contained. More important = more prominent. If everything
  shouts, nothing is heard. Start with the assumption everything is visual noise,
  guilty until proven innocent.
- **Make clickable things obviously clickable.** No relying on hover states for
  discoverability, especially on mobile where hover doesn't exist. Shape, location,
  and formatting (color, underlining) must signal clickability without interaction.
- **Eliminate noise.** Three sources: too many things shouting for attention
  (shouting), things not organized logically (disorganization), and too much stuff
  (clutter). Fix noise by removal, not addition.
- **Clarity trumps consistency.** If making something significantly clearer
  requires making it slightly inconsistent, choose clarity every time.

### Navigation as Wayfinding

Users on the web have no sense of scale, direction, or location. Navigation
must always answer: What site is this? What page am I on? What are the major
sections? What are my options at this level? Where am I? How can I search?

Persistent navigation on every page. Breadcrumbs for deep hierarchies.
Current section visually indicated. The "trunk test": cover everything except
the navigation. You should still know what site this is, what page you're on,
and what the major sections are. If not, the navigation has failed.

### The Goodwill Reservoir

Users start with a reservoir of goodwill. Every friction point depletes it.

**Deplete faster:** Hiding info users want (pricing, contact, shipping). Punishing
users for not doing things your way (formatting requirements on phone numbers).
Asking for unnecessary information. Putting sizzle in their way (splash screens,
forced tours, interstitials). Unprofessional or sloppy appearance.

**Replenish:** Know what users want to do and make it obvious. Tell them what they
want to know upfront. Save them steps wherever possible. Make it easy to recover
from errors. When in doubt, apologize.

### Mobile: Same Rules, Higher Stakes

All the above applies on mobile, just more so. Real estate is scarce, but never
sacrifice usability for space savings. Affordances must be VISIBLE: no cursor
means no hover-to-discover. Touch targets must be big enough (44px minimum).
Flat design can strip away useful visual information that signals interactivity.
Prioritize ruthlessly: things needed in a hurry go close at hand, everything
else a few taps away with an obvious path to get there.

## SETUP

{{include lib/snippets/browse-detect.md}}

## Step 0: Input Detection

Detect what design context exists for this project. Run all four checks — each is a
fresh shell, so each derives the project slug itself:

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
setopt +o nomatch 2>/dev/null || true
_CEO=$(ls -t "${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/ceo-plans/"*.md 2>/dev/null | head -1)
[ -n "$_CEO" ] && echo "CEO_PLAN: $_CEO" || echo "NO_CEO_PLAN"
```

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
setopt +o nomatch 2>/dev/null || true
_APPROVED=$(ls -t "${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/designs/"*/approved.json 2>/dev/null | head -1)
[ -n "$_APPROVED" ] && echo "APPROVED: $_APPROVED" || echo "NO_APPROVED"
```

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
setopt +o nomatch 2>/dev/null || true
_VARIANTS=$(ls -t "${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/designs/"*/variant-*.png 2>/dev/null | head -1)
[ -n "$_VARIANTS" ] && echo "VARIANTS: $_VARIANTS" || echo "NO_VARIANTS"
```

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
setopt +o nomatch 2>/dev/null || true
_FINALIZED=$(ls -t "${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/designs/"*/finalized.html 2>/dev/null | head -1)
[ -n "$_FINALIZED" ] && echo "FINALIZED: $_FINALIZED" || echo "NO_FINALIZED"
[ -f DESIGN.md ] && echo "DESIGN_MD: exists" || echo "NO_DESIGN_MD"
```

Now route based on what was found. Check these cases in order:

### Case A: approved.json exists (design-shotgun ran)

If `APPROVED` was found, read it. Extract: the approved image, user feedback, screen
name. The approved image is the file the record's `approved_path` names. An older
record without `approved_path` points at `variant-<approved_variant>.png` in the
directory that holds `approved.json`. If that file does not exist, stop and tell the
user the approved image is gone and they need to reselect with /design-shotgun; never
substitute another variant. Also read the CEO plan if one exists (it adds strategic
context).

Read `DESIGN.md` if it exists in the repo root. These tokens take priority for
system-level values (fonts, brand colors, spacing scale).

Then check for prior finalized.html. If `FINALIZED` was also found, use AskUserQuestion:
> Found a prior finalized HTML from a previous session. Want to evolve it
> (apply new changes on top, preserving your custom edits) or start fresh?
> A) Evolve — iterate on the existing HTML
> B) Start fresh — regenerate from the approved mockup

If evolve: read the existing HTML. Apply changes on top during Step 3.
If fresh or no finalized.html: proceed to Step 1 with the approved PNG as the
visual reference.

### Case B: CEO plan and/or design variants exist, but no approved.json

If `CEO_PLAN` or `VARIANTS` was found but no `APPROVED`:

Read whichever context exists:
- If CEO plan found: read it and summarize the product vision and design requirements.
- If variant PNGs found: show them inline using the Read tool.
- If DESIGN.md found: read it for design tokens and constraints.

Use AskUserQuestion:
> Found [CEO plan from /plan-ceo-review | design review variants from /plan-design-review | both]
> but no approved design mockup.
> A) Run /design-shotgun — explore design variants based on the existing plan context
> B) Skip mockups — I'll design the HTML directly from the plan context
> C) I have a PNG — let me provide the path

If A: tell the user to run /design-shotgun, then come back to /design-html.
If B: proceed to Step 1 in "plan-driven mode." There is no approved PNG, the plan is
the source of truth. Ask the user for a screen name to use for the output directory
(e.g., "landing-page", "dashboard", "pricing").
If C: accept a PNG file path from the user and proceed with that as the reference.

### Case C: Nothing found (clean slate)

If none of the above produced any context:

Use AskUserQuestion:
> No design context found for this project. How do you want to start?
> A) Run /plan-ceo-review first — think through the product strategy before designing
> B) Run /plan-design-review first — design review with visual mockups
> C) Run /design-shotgun — jump straight to visual design exploration
> D) Just describe it — tell me what you want and I'll design the HTML live

If A, B, or C: tell the user to run that skill, then come back to /design-html.
If D: proceed to Step 1 in "freeform mode." Ask the user for a screen name.

### Context summary

After routing, output a brief context summary:
- **Mode:** approved-mockup | plan-driven | freeform | evolve
- **Visual reference:** path to approved PNG, or "none (plan-driven)" or "none (freeform)"
- **CEO plan:** path or "none"
- **Design tokens:** "DESIGN.md" or "none"
- **Screen name:** from approved.json, user-provided, or inferred from CEO plan

---

## Step 1: Design Analysis

1. Read the approved PNG inline using the Read tool and build the implementation
   spec from it yourself: colors as hex, typography (family, weights, scale), layout
   structure, and a component inventory. Where the image is ambiguous — an exact hex,
   a font family you cannot name — say so and take the value from DESIGN.md or the
   plan rather than guessing a number that will look authoritative and be wrong.

2. If in plan-driven or freeform mode (no approved PNG), design from context:
   - **Plan-driven:** read the CEO plan and/or design review notes. Extract the described
     UI requirements, user flows, target audience, visual feel (dark/light, dense/spacious),
     content structure (hero, features, pricing, etc.), and design constraints. Build an
     implementation spec from the plan's prose rather than a visual reference.
   - **Freeform:** use AskUserQuestion to gather what the user wants to build. Ask about:
     purpose/audience, visual feel (dark/light, playful/serious, dense/spacious),
     content structure (hero, features, pricing, etc.), and any reference sites they like.
   In both cases, describe the intended visual layout, colors, typography, and
   component structure as your implementation spec. Generate realistic content based
   on the plan or user description (never lorem ipsum).

3. Read `DESIGN.md` tokens. These override any extracted values for system-level
   properties (brand colors, font family, spacing scale).

4. Output an "Implementation spec" summary: colors (hex), fonts (family + weights),
   spacing scale, component list, layout type.

---

## Step 2: Smart Pretext API Routing

Analyze the approved design and classify it into a Pretext tier. Each tier uses
different Pretext APIs for optimal results:

| Design type | Pretext APIs | Use case |
|-------------|-------------|----------|
| Simple layout (landing, marketing) | `prepare()` + `layout()` | Resize-aware heights |
| Card/grid (dashboard, listing) | `prepare()` + `layout()` | Self-sizing cards |
| Chat/messaging UI | `prepareWithSegments()` + `walkLineRanges()` | Tight-fit bubbles, min-width |
| Content-heavy (editorial, blog) | `prepareWithSegments()` + `layoutNextLine()` | Text around obstacles |
| Complex editorial | Full engine + `layoutWithLines()` | Manual line rendering |

State the chosen tier and why. Reference the specific Pretext APIs that will be used.

---

## Step 2.5: Framework Detection

Check if the user's project uses a frontend framework:

```bash
[ -f package.json ] && cat package.json | grep -o '"react"\|"svelte"\|"vue"\|"@angular/core"\|"solid-js"\|"preact"' | head -1 || echo "NONE"
```

If a framework is detected, use AskUserQuestion:
> Detected [React/Svelte/Vue] in your project. What format should the output be?
> A) Vanilla HTML — self-contained preview file (recommended for first pass)
> B) [React/Svelte/Vue] component — framework-native with Pretext hooks

If the user chooses framework output, ask one follow-up:
> A) TypeScript
> B) JavaScript

For vanilla HTML: proceed to Step 3 with vanilla output.
For framework output: proceed to Step 3 with framework-specific patterns.
If no framework detected: default to vanilla HTML, no question needed.

---

## Step 3: Generate Pretext-Native HTML

### Pretext Source Embedding

For **vanilla HTML output**: no Pretext bundle ships with this skill, so the page
imports Pretext from the CDN as an ES module. Pretext is ESM-only and sets no global,
so the import and all page code that calls it go in the same `<script type="module">`.
The import pins an exact version, so a later release cannot change a page that already
works:
```html
<script type="module">
  import { prepare, layout, prepareWithSegments, walkLineRanges, layoutNextLine, layoutWithLines } from 'https://esm.sh/@chenglou/pretext@0.0.9'
  // page code (the wiring patterns below) goes here, after the import
</script>
```
Tell the user the page needs the network to lay itself out: on an offline machine or
behind a CSP that blocks esm.sh it renders unlaid-out. If they need a fully
self-contained file, they install `@chenglou/pretext` in their own project and use
framework output (or their bundler) instead.

For **framework output**, add to the project's dependencies instead:
```bash
# Detect package manager
[ -f bun.lockb ] && echo "bun add @chenglou/pretext" || \
[ -f pnpm-lock.yaml ] && echo "pnpm add @chenglou/pretext" || \
[ -f yarn.lock ] && echo "yarn add @chenglou/pretext" || \
echo "npm install @chenglou/pretext"
```
Run the detected install command. Then use standard imports in the component.

### HTML Generation

Resolve the output directory first (fill in `<screen-name>`):

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)"
_DESIGN_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/$SLUG/designs/<screen-name>-$(date +%Y%m%d)"
mkdir -p "$_DESIGN_DIR"
echo "DESIGN_DIR: $_DESIGN_DIR"
```

Write a single file using the Write tool. Save to `<DESIGN_DIR>/finalized.html`,
where `<DESIGN_DIR>` is the path the block printed on its `DESIGN_DIR:` line.

For framework output, save to `<DESIGN_DIR>/finalized.[tsx|svelte|vue]`.

**Always include in vanilla HTML:**
- Pretext imported from esm.sh in a `<script type="module">` (see above)
- CSS custom properties for design tokens from DESIGN.md / Step 1 extraction
- Google Fonts via `<link>` tags + `document.fonts.ready` gate before first `prepare()`
- Semantic HTML5 (`<header>`, `<nav>`, `<main>`, `<section>`, `<footer>`)
- Responsive behavior via Pretext relayout (not just media queries)
- Breakpoint-specific adjustments at 375px, 768px, 1024px, 1440px
- ARIA attributes, heading hierarchy, focus-visible states
- `contenteditable` on text elements + MutationObserver to re-prepare + re-layout on edit
- ResizeObserver on containers to re-layout on resize
- `prefers-color-scheme` media query for dark mode
- `prefers-reduced-motion` for animation respect
- Real content extracted from the mockup (never lorem ipsum)

**Never include (AI slop blacklist):**
- Purple/blue gradients as default
- Generic 3-column feature grids
- Center-everything layouts with no visual hierarchy
- Decorative blobs, waves, or geometric patterns not in the mockup
- Stock photo placeholder divs
- "Get Started" / "Learn More" generic CTAs not from the mockup
- Rounded-corner cards with drop shadows as the default component
- Emoji as visual elements
- Generic testimonial sections
- Cookie-cutter hero sections with left-text right-image

### Pretext Wiring Patterns

Use these patterns based on the tier selected in Step 2. These are the correct
Pretext API usage patterns. Follow them exactly. The imports below are for framework
output; in vanilla HTML, import the same names from `'https://esm.sh/@chenglou/pretext@0.0.9'`
once, at the top of the page's `<script type="module">`.

**Pattern 1: Basic height computation (Simple layout, Card/grid)**
```js
import { prepare, layout } from '@chenglou/pretext'

// 1. PREPARE — one-time, after fonts load
await document.fonts.ready
const elements = document.querySelectorAll('[data-pretext]')
const prepared = new Map()

for (const el of elements) {
  const text = el.textContent
  const font = getComputedStyle(el).font
  prepared.set(el, prepare(text, font))
}

// 2. LAYOUT — cheap, call on every resize
function relayout() {
  for (const [el, handle] of prepared) {
    const { height } = layout(handle, el.clientWidth, parseFloat(getComputedStyle(el).lineHeight))
    el.style.height = `${height}px`
  }
}

// 3. RESIZE-AWARE
new ResizeObserver(() => relayout()).observe(document.body)
relayout()

// 4. CONTENT-EDITABLE — re-prepare when text changes
for (const el of elements) {
  if (el.contentEditable === 'true') {
    new MutationObserver(() => {
      const font = getComputedStyle(el).font
      prepared.set(el, prepare(el.textContent, font))
      relayout()
    }).observe(el, { characterData: true, subtree: true, childList: true })
  }
}
```

**Pattern 2: Shrinkwrap / tight-fit containers (Chat bubbles)**
```js
import { prepareWithSegments, walkLineRanges } from '@chenglou/pretext'

// Tight-fit width: lay out at maxWidth, then shrink the bubble to its widest line
function shrinkwrap(text, font, maxWidth) {
  const segs = prepareWithSegments(text, font)
  let widest = 0
  const lineCount = walkLineRanges(segs, maxWidth, (line) => {
    widest = Math.max(widest, line.width)
  })
  return { width: Math.ceil(widest), lineCount }
}
```

**Pattern 3: Text around obstacles (Editorial layout)**
```js
import { prepareWithSegments, layoutNextLine } from '@chenglou/pretext'

function layoutAroundObstacles(text, font, containerWidth, lineHeight, obstacles) {
  const segs = prepareWithSegments(text, font)
  let cursor = { segmentIndex: 0, graphemeIndex: 0 }
  let y = 0
  const lines = []

  while (true) {
    // Calculate available width at current y position, accounting for obstacles
    let availWidth = containerWidth
    for (const obs of obstacles) {
      if (y >= obs.top && y < obs.top + obs.height) {
        availWidth -= obs.width
      }
    }

    const result = layoutNextLine(segs, cursor, availWidth)
    if (!result) break

    lines.push({ text: result.text, width: result.width, x: 0, y })
    cursor = result.end
    y += lineHeight
  }

  return { lines, totalHeight: y }
}
```

**Pattern 4: Full line-by-line rendering (Complex editorial)**
```js
import { prepareWithSegments, layoutWithLines } from '@chenglou/pretext'

const segs = prepareWithSegments(text, font)
const { lines, height } = layoutWithLines(segs, containerWidth, lineHeight)

// lines = [{ text, width, start, end }, ...] (no x/y: line i sits at y = i * lineHeight)
// Use for Canvas/SVG rendering or custom DOM positioning
lines.forEach((line, i) => {
  const span = document.createElement('span')
  span.textContent = line.text
  span.style.position = 'absolute'
  span.style.left = '0px'
  span.style.top = `${i * lineHeight}px`
  container.appendChild(span)
})
```

### Pretext API Reference

```
PRETEXT API CHEATSHEET:

prepare(text, font) → handle
  One-time text measurement. Call after document.fonts.ready.
  Font: CSS shorthand like '16px Inter' or 'bold 24px Georgia'.

layout(prepared, maxWidth, lineHeight) → { height, lineCount }
  Fast layout computation. Call on every resize. Sub-millisecond.

prepareWithSegments(text, font) → handle
  Like prepare() but enables line-level APIs below.

layoutWithLines(segs, maxWidth, lineHeight) → { lineCount, height, lines: [{text, width, start, end}...] }
  Full line-by-line breakdown (no x/y: line i is at y = i * lineHeight). For Canvas/SVG rendering.

walkLineRanges(segs, maxWidth, onLine) → lineCount
  Calls onLine({ width, start, end }) once per line at maxWidth (no text built).
  The widest line's width is the tight-fit container width. For chat bubbles.

layoutNextLine(segs, cursor, maxWidth) → { text, width, start, end } | null
  Iterator. Different maxWidth per line = text around obstacles.
  Start with cursor { segmentIndex: 0, graphemeIndex: 0 }; pass result.end next.
  Returns null when text is exhausted. Takes no lineHeight: advance y yourself.

clearCache() → void
  Clears internal measurement caches. Use when cycling many fonts.

setLocale(locale?) → void
  Retargets word segmenter for future prepare() calls.
```

---

## Step 3.5: Live Reload Server

After writing the HTML file, start a simple HTTP server for live preview:

```bash
# Start a simple HTTP server in the output directory
_OUTPUT_DIR=$(dirname <path-to-finalized.html>)
cd "$_OUTPUT_DIR"
python3 -m http.server 0 --bind 127.0.0.1 &
_SERVER_PID=$!
# The server needs a moment to bind; wait for its listening socket before reading the port.
_PORT=""
for _i in 1 2 3 4 5 6 7 8 9 10; do
  _PORT=$(lsof -a -p "$_SERVER_PID" -iTCP -sTCP:LISTEN -P -n -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p' | head -1)
  [ -n "$_PORT" ] && break
  sleep 0.2
done
[ -n "$_PORT" ] || { echo "SERVER_FAILED: no listening port after 2s" >&2; kill "$_SERVER_PID" 2>/dev/null; exit 1; }
echo "SERVER: http://127.0.0.1:$_PORT/finalized.html"
echo "PID: $_SERVER_PID"
```

Remember the printed `SERVER:` URL and `PID:` value. Each bash block is a fresh
shell, so `$_PORT` and `$_SERVER_PID` are empty in later blocks: restate the URL and
PID literally wherever they are needed.

If python3 is not available, fall back to:
```bash
open <path-to-finalized.html>
```

Tell the user: "Live preview running at <SERVER URL>.
After each edit, just refresh the browser (Cmd+R) to see changes."

When the refinement loop ends (Step 4 exits), kill the server:
```bash
kill <PID> 2>/dev/null || true
```

---

## Step 4: Preview + Refinement Loop

### Verification Screenshots

If SETUP printed `BROWSE_AVAILABLE`, take verification screenshots at 3 viewports.
`screenshot` has no width flag, so set the viewport before each capture. Load the
page through the live-reload server's `SERVER:` URL (not `file://`), so the module
import and relative assets resolve. This is a fresh shell, so replace `<BROWSE_BIN>`
with the path SETUP printed on its `BROWSE_BIN:` line:

```bash
B='<BROWSE_BIN>'
$B goto "<SERVER URL>"
$B viewport 375x812
$B screenshot /tmp/vibestack-verify-mobile.png
$B viewport 768x1024
$B screenshot /tmp/vibestack-verify-tablet.png
$B viewport 1440x900
$B screenshot /tmp/vibestack-verify-desktop.png
```

If the live-reload server is not running (no python3), skip the screenshots rather
than pointing the browser at a `file://` path.

Show all three screenshots inline using the Read tool. Check for:
- Text overflow (text cut off or extending beyond containers)
- Layout collapse (elements overlapping or missing)
- Responsive breakage (content not adapting to viewport)

If issues are found, note them and fix before presenting to the user.

If SETUP printed `BROWSE_NOT_AVAILABLE`, skip verification and note:
"Browse binary not available. Skipping automated viewport verification."

### Refinement Loop

```
LOOP:
  1. If server is running, tell user to open the printed `SERVER:` URL
     Otherwise: open <path>/finalized.html

  2. If an approved mockup PNG exists, show it inline (Read tool) for visual comparison.
     If in plan-driven or freeform mode, skip this step.

  3. AskUserQuestion (adjust wording based on mode):
     With mockup: "The HTML is live in your browser. Here's the approved mockup for comparison.
      Try: resize the window (text should reflow dynamically),
      click any text (it's editable, layout recomputes instantly).
      What needs to change? Say 'done' when satisfied."
     Without mockup: "The HTML is live in your browser. Try: resize the window
      (text should reflow dynamically), click any text (it's editable, layout
      recomputes instantly). What needs to change? Say 'done' when satisfied."

  4. If "done" / "ship it" / "looks good" / "perfect" → exit loop, go to Step 5

  5. Apply feedback using targeted Edit tool changes on the HTML file
     (do NOT regenerate the entire file — surgical edits only)

  6. Brief summary of what changed (2-3 lines max)

  7. If verification screenshots are available, re-take them to confirm the fix

  8. Go to LOOP
```

Maximum 10 iterations. If the user hasn't said "done" after 10, use AskUserQuestion:
"We've done 10 rounds of refinement. Want to continue iterating or call it done?"

---

## Step 5: Save & Next Steps

### Design Token Extraction

If no `DESIGN.md` exists in the repo root, offer to create one from the generated HTML:

Extract from the HTML:
- CSS custom properties (colors, spacing, font sizes)
- Font families and weights used
- Color palette (primary, secondary, accent, neutral)
- Spacing scale
- Border radius values
- Shadow values

Use AskUserQuestion:
> No DESIGN.md found. I can extract the design tokens from the HTML we just built
> and create a DESIGN.md for your project. This means future /design-shotgun and
> /design-html runs will be style-consistent automatically.
> A) Create DESIGN.md from these tokens
> B) Skip — I'll handle the design system later

If A: write `DESIGN.md` to the repo root with the extracted tokens.

### Save Metadata

Write `finalized.json` alongside the HTML:
```json
{
  "source_mockup": "<approved variant PNG path or null>",
  "source_plan": "<CEO plan path or null>",
  "mode": "<approved-mockup|plan-driven|freeform|evolve>",
  "html_file": "<path to finalized.html or component file>",
  "pretext_tier": "<selected tier>",
  "framework": "<vanilla|react|svelte|vue>",
  "iterations": <number of refinement iterations>,
  "date": "<ISO 8601>",
  "screen": "<screen name>",
  "branch": "<current branch>"
}
```

### Next Steps

Use AskUserQuestion:
> Design finalized with Pretext-native layout. What's next?
> A) Copy to project — copy the HTML/component into your codebase
> B) Iterate more — keep refining
> C) Done — I'll use this as a reference

---

## Important Rules

- **Source of truth fidelity over code elegance.** When an approved mockup exists,
  pixel-match it. If that requires `width: 312px` instead of a CSS grid class, that's
  correct. When in plan-driven or freeform mode, the user's feedback during the
  refinement loop is the source of truth. Code cleanup happens later during
  component extraction.

- **Always use Pretext for text layout.** Even if the design looks simple, Pretext
  ensures correct height computation on resize. The overhead is 30KB. Every page benefits.

- **Surgical edits in the refinement loop.** Use the Edit tool to make targeted changes,
  not the Write tool to regenerate the entire file. The user may have made manual edits
  via contenteditable that should be preserved.

- **Real content only.** When a mockup exists, extract text from it. In plan-driven mode,
  use content from the plan. In freeform mode, generate realistic content based on the
  user's description. Never use "Lorem ipsum", "Your text here", or placeholder content.

- **One page per invocation.** For multi-page designs, run /design-html once per page.
  Each run produces one HTML file.

{{include lib/snippets/askuserquestion-split.md}}
