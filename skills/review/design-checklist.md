# Design Review Checklist (Lite)

> **Subset of DESIGN_METHODOLOGY** — when adding items here, also update `generateDesignMethodology()` in `scripts/gen-skill-docs.ts`, and vice versa.

## Instructions

This checklist applies to **source code in the diff** — not rendered output. Read each changed frontend file (full file, not just diff hunks) and flag anti-patterns.

**Trigger:** Only run this checklist if the diff touches frontend files. Use git diff to detect:

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-diff-scope" <base> 2>/dev/null || true)"
echo "SCOPE_FRONTEND=${SCOPE_FRONTEND:-false}"
```

If `SCOPE_FRONTEND=false`, skip the entire design review silently.

**DESIGN.md calibration:** If `DESIGN.md` or `design-system.md` exists in the repo root, read it first. All findings are calibrated against the project's stated design system. Patterns explicitly blessed in DESIGN.md are NOT flagged. If no DESIGN.md exists, use universal design principles.

---

## Confidence Tiers

Each item is tagged with a detection confidence level:

- **[HIGH]** — Reliably detectable via grep/pattern match. Definitive findings.
- **[MEDIUM]** — Detectable via pattern aggregation or heuristic. Flag as findings but expect some noise.
- **[LOW]** — Requires understanding visual intent. Present as: "Possible issue — verify visually or run /design-review."

---

## Classification

**AUTO-FIX** (mechanical CSS fixes only — HIGH confidence, no design judgment needed):
- `outline: none` without replacement → add `outline: revert` or `&:focus-visible { outline: 2px solid currentColor; }`
- `!important` in new CSS → remove and fix specificity
- `font-size` < 16px on body text → bump to 16px

**ASK** (everything else — requires design judgment):
- All AI slop findings, typography structure, spacing choices, interaction state gaps, DESIGN.md violations

**LOW confidence items** → present as "Possible: [description]. Verify visually or run /design-review." Never AUTO-FIX.

---

## Output Format

```
Design Review: N issues (X auto-fixable, Y need input, Z possible)

**AUTO-FIXED:**
- [file:line] Problem → fix applied

**NEEDS INPUT:**
- [file:line] Problem description
  Recommended fix: suggested fix

**POSSIBLE (verify visually):**
- [file:line] Possible issue — verify with /design-review
```

Optional: `test_stub` — skeleton test code for this finding using the project's test framework.

If no issues found: `Design Review: No issues found.`

If no frontend files changed: skip silently, no output.

---

## Categories

### 1. AI Slop Detection (10 items) — highest priority

These are the telltale signs of AI-generated UI that no designer at a respected studio would ship. Cite the rule id with each finding.

- **[slop-purple-gradient] [MEDIUM]** Purple/violet/indigo gradient backgrounds or blue-to-purple color schemes. Look for `linear-gradient` with values in the `#6366f1`–`#8b5cf6` range, or CSS custom properties resolving to purple/violet.

- **[slop-three-column-grid] [LOW]** The 3-column feature grid: icon-in-colored-circle + bold title + 2-line description, repeated 3x symmetrically. Look for a grid/flex container with exactly 3 children that each contain a circular element + heading + paragraph.

- **[slop-icon-circles] [LOW]** Icons in colored circles as section decoration. Look for elements with `border-radius: 50%` + a background color used as decorative containers for icons.

- **[slop-centered-everything] [HIGH]** `text-align: center` on all headings, descriptions, and cards. Grep for `text-align: center` density — if >60% of text containers use center alignment, flag it.

- **[slop-uniform-radius] [MEDIUM]** Uniform bubbly border-radius on every element: same large radius (16px+) applied to cards, buttons, inputs, containers uniformly. Aggregate `border-radius` values — if >80% use the same value ≥16px, flag it.

- **[slop-generic-hero] [MEDIUM]** Generic hero copy: "Welcome to [X]", "Unlock the power of...", "Your all-in-one solution for...", "Revolutionize your...", "Streamline your workflow". Grep HTML/JSX content for these patterns.

- **[slop-layout-transition] [HIGH]** Transitions or animations on layout properties (`width`, `height`, `top`, `left`, `margin`, `padding`) or `transition: all` — they reflow every frame. Animate `transform` and `opacity`.

- **[slop-justified-text] [HIGH]** `text-align: justify` on body text without hyphenation — it opens rivers of whitespace, worst on narrow screens.

- **[slop-tiny-text] [HIGH]** Any text below 12px (`font-size` < 12px or < 0.75rem), including captions, labels and legal copy.

- **[slop-all-caps-body] [MEDIUM]** `text-transform: uppercase` (or literal capitals) on body copy or anything longer than a short label — it slows reading.

Everything else the craft floor covers (hierarchy, rhythm, color restraint, motion purpose) is for `/design-review` on the rendered page, not this code-level pass.

### 2. Typography (4 items)

- **[HIGH]** Body text `font-size` < 16px. Grep for `font-size` declarations on `body`, `p`, `.text`, or base styles. Values below 16px (or 1rem when base is 16px) are flagged.

- **[HIGH]** More than 3 font families introduced in the diff. Count distinct `font-family` declarations. Flag if >3 unique families appear across changed files.

- **[HIGH]** Heading hierarchy skipping levels: `h1` followed by `h3` without an `h2` in the same file/component. Check HTML/JSX for heading tags.

- **[HIGH]** Blacklisted fonts: Papyrus, Comic Sans, Lobster, Impact, Jokerman. Grep `font-family` for these names.

### 3. Spacing & Layout (4 items)

- **[MEDIUM]** Arbitrary spacing values not on a 4px or 8px scale, when DESIGN.md specifies a spacing scale. Check `margin`, `padding`, `gap` values against the stated scale. Only flag when DESIGN.md defines a scale.

- **[MEDIUM]** Fixed widths without responsive handling: `width: NNNpx` on containers without `max-width` or `@media` breakpoints. Risk of horizontal scroll on mobile.

- **[MEDIUM]** Missing `max-width` on text containers: body text or paragraph containers with no `max-width` set, allowing lines >75 characters. Check for `max-width` on text wrappers.

- **[HIGH]** `!important` in new CSS rules. Grep for `!important` in added lines. Almost always a specificity escape hatch that should be fixed properly.

### 4. Interaction States (3 items)

- **[MEDIUM]** Interactive elements (buttons, links, inputs) missing hover/focus states. Check if `:hover` and `:focus` or `:focus-visible` pseudo-classes exist for new interactive element styles.

- **[HIGH]** `outline: none` or `outline: 0` without a replacement focus indicator. Grep for `outline:\s*none` or `outline:\s*0`. This removes keyboard accessibility.

- **[LOW]** Touch targets < 44px on interactive elements. Check `min-height`/`min-width`/`padding` on buttons and links. Requires computing effective size from multiple properties — low confidence from code alone.

### 5. DESIGN.md Violations (3 items, conditional)

Only apply if `DESIGN.md` or `design-system.md` exists:

- **[MEDIUM]** Colors not in the stated palette. Compare color values in changed CSS against the palette defined in DESIGN.md.

- **[MEDIUM]** Fonts not in the stated typography section. Compare `font-family` values against DESIGN.md's font list.

- **[MEDIUM]** Spacing values outside the stated scale. Compare `margin`/`padding`/`gap` values against DESIGN.md's spacing scale.

---

## Suppressions

Do NOT flag:
- Patterns explicitly documented in DESIGN.md as intentional choices
- Third-party/vendor CSS files (node_modules, vendor directories)
- CSS resets or normalize stylesheets
- Test fixture files
- Generated/minified CSS
