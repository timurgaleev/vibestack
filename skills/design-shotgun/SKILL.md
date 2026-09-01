---
name: design-shotgun
description: |
  Design shotgun: generate multiple AI design variants, review them side by side, collect structured feedback, and iterate. Standalone design exploration you can run anytime.
triggers:
  - explore design variants
  - show me design options
  - visual design brainstorm
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - Agent
  - AskUserQuestion
---

## When to invoke

Use when: "explore designs", "show me options", "design variants", "visual brainstorm", or "I don't like how this looks".

Proactively suggest when the user describes a UI feature but hasn't seen what it could look like.

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

---

# /design-shotgun: Visual Design Exploration

You are a design brainstorming partner. Generate multiple design variants, show
them side by side, and iterate until the user approves a direction. This is visual
brainstorming, not a review process — your job is divergence, not judgement. Save
the critique for /design-review.

## SETUP

{{include lib/snippets/browse-detect.md}}

## DESIGN SETUP

```bash
# Bind $D to vibe-design (OpenAI image backend) when a key is configured.
D=~/.vibestack/bin/vibe-design
if [ -x "$D" ] && [ "$("$D" status 2>/dev/null)" = "DESIGN_AVAILABLE" ]; then
  echo "DESIGN_AVAILABLE via $D"
else
  echo "DESIGN_NOT_AVAILABLE"
fi
```

If `DESIGN_NOT_AVAILABLE`: skip visual mockup generation and fall back to text-based design review.

`$D` generates image variants — nothing else. There is no comparison board to serve,
no vision critique, and no refine-in-place verb: the review happens in the
conversation, with you reading each PNG inline. Never invent a subcommand; anything
other than `status` and `variants` either reports that it is unsupported or exits
with a usage error.

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

## Step 0: Session Detection

Check for prior design exploration sessions for this project:

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
setopt +o nomatch 2>/dev/null || true
_PREV=$(find ~/.vibestack/projects/$SLUG/designs/ -name "approved.json" -maxdepth 2 2>/dev/null | sort -r | head -5)
[ -n "$_PREV" ] && echo "PREVIOUS_SESSIONS_FOUND" || echo "NO_PREVIOUS_SESSIONS"
echo "$_PREV"
```

**If `PREVIOUS_SESSIONS_FOUND`:** Read each `approved.json`, display a summary, then
AskUserQuestion:

> "Previous design explorations for this project:
> - [date]: [screen] — chose variant [X], feedback: '[summary]'
>
> A) Revisit — re-read the variants from that session and reconsider your pick
> B) New exploration — start fresh with new or updated instructions
> C) Something else"

If A: read the variant PNGs from that session's directory back in with the Read
tool, present them one at a time, and resume the feedback loop from there. There
is no comparison board to reopen — the loop is inline, in this conversation.
If B: proceed to Step 1.

**If `NO_PREVIOUS_SESSIONS`:** Show the first-time message:

"This is /design-shotgun — your visual brainstorming tool. I'll generate multiple AI
design directions and show them to you here, one at a time, and you pick your favorite.
You can run /design-shotgun anytime during development to explore design directions for
any part of your product. Let's start."

## Step 1: Context Gathering

When design-shotgun is invoked from plan-design-review, design-consultation, or another
skill, the calling skill has already gathered context. Check for `$_DESIGN_BRIEF` — if
it's set, skip to Step 2.

When run standalone, gather context to build a proper design brief.

**Required context (5 dimensions):**
1. **Who** — who is the design for? (persona, audience, expertise level)
2. **Job to be done** — what is the user trying to accomplish on this screen/page?
3. **What exists** — what's already in the codebase? (existing components, pages, patterns)
4. **User flow** — how do users arrive at this screen and where do they go next?
5. **Edge cases** — long names, zero results, error states, mobile, first-time vs power user

**Auto-gather first:**

```bash
cat DESIGN.md 2>/dev/null | head -80 || echo "NO_DESIGN_MD"
```

```bash
ls src/ app/ pages/ components/ 2>/dev/null | head -30
```

```bash
setopt +o nomatch 2>/dev/null || true
ls ~/.vibestack/projects/$SLUG/*office-hours* 2>/dev/null | head -5
```

If DESIGN.md exists, tell the user: "I'll follow your design system in DESIGN.md by
default. If you want to go off the reservation on visual direction, just say so —
design-shotgun will follow your lead, but won't diverge by default."

**Check for a live site to screenshot** (for the "I don't like THIS" use case):

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null || echo "NO_LOCAL_SITE"
```

If a local site is running AND the user referenced a URL or said something like "I don't
like how this looks," screenshot the current page with `$B` and read the screenshot
inline. Describe what is there — layout, palette, type, the specific things that make
it feel wrong — and fold that description into every variant brief as the starting
point to improve on. That description is the whole evolve mechanism: `$D` has no verb
that takes a screenshot.

**AskUserQuestion with pre-filled context:** Pre-fill what you inferred from the codebase,
DESIGN.md, and office-hours output. Then ask for what's missing. Frame as ONE question
covering all gaps:

> "Here's what I know: [pre-filled context]. I'm missing [gaps].
> Tell me: [specific questions about the gaps].
> How many variants? (default 3, up to 8 for important screens)"

Two rounds max of context gathering, then proceed with what you have and note assumptions.

## Step 2: Taste Memory

Read both the persistent taste profile (cross-session) AND the per-session approved
designs to bias generation toward the user's demonstrated taste.

**Persistent taste profile (v1 schema at `~/.vibestack/projects/$SLUG/taste-profile.json`):**

Read the persistent taste profile if it exists:

```bash
_TASTE_PROFILE=~/.vibestack/projects/$SLUG/taste-profile.json
if [ -f "$_TASTE_PROFILE" ]; then
  # Schema v1: { dimensions: { fonts, colors, layouts, aesthetics }, sessions: [] }
  # Each dimension has approved[] and rejected[] entries with
  # { value, confidence, approved_count, rejected_count, last_seen }
  # Confidence decays 5% per week of inactivity — computed at read time.
  cat "$_TASTE_PROFILE" 2>/dev/null | head -200
  echo "TASTE_PROFILE_FOUND"
else
  echo "NO_TASTE_PROFILE"
fi
```

**If TASTE_PROFILE_FOUND:** Summarize the strongest signals (top 3 approved entries
per dimension by confidence * approved_count). Include them in the design brief:

"Based on \${SESSION_COUNT} prior sessions, this user's taste leans toward:
fonts [top-3], colors [top-3], layouts [top-3], aesthetics [top-3]. Bias
generation toward these unless the user explicitly requests a different direction.
Also avoid their strong rejections: [top-3 rejected per dimension]."

**If NO_TASTE_PROFILE:** Fall through to per-session approved.json files (legacy).

**Conflict handling:** If the current user request contradicts a strong persistent
signal (e.g., "make it playful" when taste profile strongly prefers minimal), flag
it: "Note: your taste profile strongly prefers minimal. You're asking for playful
this time — I'll proceed, but want me to update the taste profile, or treat this
as a one-off?"

**Decay:** Confidence scores decay 5% per week. A font approved 6 months ago with
10 approvals has less weight than one approved last week. The decay calculation
happens at read time, not write time, so the file only grows on change.

**Legacy files:** If the file has no `version` field or `version: 0`, it is the
older per-session `approved.json` aggregate rather than a v1 profile. Nothing
migrates it for you — read what it does carry (approved values, dates) and treat
the confidence and count fields as absent instead of assuming they are there.

The profile itself is maintained outside this skill, so it may simply not exist.
When it doesn't, the project's learnings log is the cross-session taste signal —
the preamble already loaded it.

**Per-session approved.json files (legacy, still supported):**

```bash
setopt +o nomatch 2>/dev/null || true
_TASTE=$(find ~/.vibestack/projects/$SLUG/designs/ -name "approved.json" -maxdepth 2 2>/dev/null | sort -r | head -10)
```

If prior sessions exist, read each `approved.json` and extract patterns from the
approved variants. Merge these into the taste-profile.json-derived signal — if the
profile already says "user prefers Geist font" (from aggregated history), the
approved.json files add the specific recent approval context.

Limit to last 10 sessions. Try/catch JSON parse on each (skip corrupted files).

**Recording taste after a design-shotgun session:** When the user picks a variant,
log the approval as a learning; when they explicitly reject one, log the rejection
the same way. Name the *quality* they responded to, not the variant letter — "picked
the serif display over two sans variants", not "picked B" — because the letter means
nothing in the next session and the quality is what should bias the next brief.

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"design-shotgun","type":"taste","key":"<dimension: fonts|colors|layouts|aesthetics>","insight":"<approved|rejected: the quality, in one line>","confidence":<1-10>,"source":"design-shotgun"}'
```

The preamble reads these back on every future run, which is how taste accumulates
here. Nothing in this skill writes `taste-profile.json`.

## Step 3: Generate Variants

Set up the output directory:

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)"
_DESIGN_DIR="$HOME/.vibestack/projects/$SLUG/designs/<screen-name>-$(date +%Y%m%d)"
mkdir -p "$_DESIGN_DIR"
echo "DESIGN_DIR: $_DESIGN_DIR"
```

Replace `<screen-name>` with a descriptive kebab-case name from the context gathering.

### Step 3a: Concept Generation

Before any API calls, generate N text concepts describing each variant's design direction.
Each concept should be a distinct creative direction, not a minor variation. Present them
as a lettered list:

```
I'll explore 3 directions:

A) "Name" — one-line visual description of this direction
B) "Name" — one-line visual description of this direction
C) "Name" — one-line visual description of this direction
```

Draw on DESIGN.md, taste memory, and the user's request to make each concept distinct.

**Anti-convergence directive (hard requirement):** Each variant MUST use a different
font family, color palette, and layout approach. If two variants look like siblings
— same typographic feel, overlapping color temperature, comparable layout rhythm —
one of them failed. Regenerate the weaker one with a deliberately different direction.

Concrete test: if someone could swap the headline text between two variants without
noticing, they're too similar. Variants should feel like they came from three
different design teams, not the same team at three different coffee levels.

### Step 3b: Concept Confirmation

Use AskUserQuestion to confirm before spending API credits:

> "These are the {N} directions I'll generate. Each takes ~60s, but I'll run them all
> in parallel so total time is ~60 seconds regardless of count."

Options:
- A) Generate all {N} — looks good
- B) I want to change some concepts (tell me which)
- C) Add more variants (I'll suggest additional directions)
- D) Fewer variants (tell me which to drop)

If B: incorporate feedback, re-present concepts, re-confirm. Max 2 rounds.
If C: add concepts, re-present, re-confirm.
If D: drop specified concepts, re-present, re-confirm.

### Step 3c: Parallel Generation

**If evolving from a screenshot** (user said "I don't like THIS"), take ONE screenshot
first and read it inline, so the brief can name what to move away from:

```bash
$B screenshot "$_DESIGN_DIR/current.png"
```

If `BROWSE_NOT_AVAILABLE`, ask the user for a screenshot instead of skipping the step
— the current design is the whole premise of this path.

**Launch N Agent subagents in a single message** (parallel execution). Use the Agent
tool with `subagent_type: "general-purpose"` for each variant. Each agent is independent
and handles its own generation, verification, and retry.

**Important: $D path propagation.** The `$D` variable from DESIGN SETUP is a shell
variable that agents do NOT inherit. Substitute the resolved absolute path (the one
DESIGN SETUP echoed) into each agent prompt.

**Agent prompt template** (one per variant, substitute all `{...}` values):

```
Generate a design variant and save it.

Design binary: {absolute path to $D binary}
Brief: {the full variant-specific brief for this direction}
Staging dir: /tmp/variant-{letter}
Final location: {_DESIGN_DIR absolute path}/variant-{letter}.png

Steps:
1. Run: {$D path} variants --brief "{brief}" --count 1 --output-dir /tmp/variant-{letter}
   The image lands at /tmp/variant-{letter}/variant-A.png.
2. If the command prints DESIGN_ERROR mentioning a rate limit (429), wait 5 seconds
   and retry. Up to 3 retries.
3. If the output file is missing or empty after the command succeeds, retry once.
4. Copy: cp /tmp/variant-{letter}/variant-A.png {_DESIGN_DIR}/variant-{letter}.png
5. Verify: ls -lh {_DESIGN_DIR}/variant-{letter}.png
6. Report exactly one of:
   VARIANT_{letter}_DONE: {file size}
   VARIANT_{letter}_FAILED: {error description}
   VARIANT_{letter}_RATE_LIMITED: exhausted retries
```

The agents do not judge their own output — quality is gated once, by you, in Step 3d.

**Why /tmp/ then cp?** In observed sessions, generating straight into
`~/.vibestack/...` failed with "The operation was aborted" while `/tmp/...`
succeeded. This is a sandbox restriction. Always generate to `/tmp/` first, then `cp`.

### Step 3d: Results

After all agents complete:

1. Read each generated PNG inline (Read tool) so the user sees all variants at once.
2. Report status: "All {N} variants generated in ~{actual time}. {successes} succeeded,
   {failures} failed."
3. For any failures: report explicitly with the error. Do NOT silently skip.
4. If zero variants succeeded: fall back to sequential generation (one `$D variants`
   call at a time, showing each as it lands). Tell the user: "Parallel generation failed
   (likely rate limiting). Falling back to sequential..."
5. Proceed to Step 4.

**Quality gate — you are the only one.** Before showing a variant, ask yourself:
*"Would a human designer be embarrassed to put their name on this?"* If yes, discard
it and regenerate with a sharper brief. A mediocre mockup is worse than one fewer
option. Embarrassment triggers: purple gradient hero, 3-column SaaS grid,
centered-everything, generic stock-photo vibe, system-ui body text, gradient CTA
button, bubble-radius everything.

**Dynamic image list:** Build the list of what to show from the variant files that
actually exist, not a hardcoded A/B/C list:

```bash
setopt +o nomatch 2>/dev/null || true  # zsh compat
_IMAGES=$(ls "$_DESIGN_DIR"/variant-*.png 2>/dev/null | tr '\n' ',' | sed 's/,$//')
```

## Step 4: Variant Review + Feedback Loop

The review happens in the conversation: read every variant PNG inline so the user
sees the whole set at once, in the order the concepts were presented, each one
labelled with its direction name from Step 3a.

**Then use AskUserQuestion as the chooser:**

"Which direction should we take forward?"

- A) Variant A — [its direction, one line]
- B) Variant B — [its direction]
- C) Variant C — [its direction]
- D) None of these — regenerate with different directions

Add: "Tell me what you'd change about your pick, or which elements you'd take from
the others — I'll fold that into the next round."

With more than three variants this list exceeds the four-option cap. Batch or split
per the 5+-option rule at the end of this skill — never drop a variant the user paid
to generate just to make the call fit.

**If the user picks a variant with no changes:** that's the approval. Go to Step 5.

**If the user asks for a remix, a regeneration, or "more like B":** rebuild the
briefs from what they said — which variant's layout, which one's palette, what to
drop — and run Step 3c again into a fresh subdirectory of `$_DESIGN_DIR` (e.g.
`round-2/`) so the earlier round stays readable. Show the new set and ask again.

**Round cap: 3.** After the third round, ask whether to keep iterating or settle on
the closest variant so far. Unbounded regeneration burns API credits and rarely
converges — if three rounds haven't landed it, the brief is the problem, not the
generation.

**After receiving feedback (any path):** Output a clear summary confirming
what was understood:

"Here's what I understood from your feedback:
PREFERRED: Variant [X]
RATINGS: [list]
YOUR NOTES: [comments]
DIRECTION: [overall]

Is this right?"

Use AskUserQuestion to verify before proceeding.

**Save the approved choice:**
```bash
echo '{"approved_variant":"<V>","feedback":"<FB>","date":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","screen":"<SCREEN>","branch":"'$(git branch --show-current 2>/dev/null)'"}' > "$_DESIGN_DIR/approved.json"
```

## Step 5: Feedback Confirmation

After the user has chosen, output a clear summary confirming what was understood:

"Here's what I understood from your feedback:

PREFERRED: Variant [X]
RATINGS: whatever they ranked, if they ranked anything
YOUR NOTES: [full text of per-variant and overall comments]
DIRECTION: [regenerate action if any]

Is this right?"

Use AskUserQuestion to confirm before saving.

## Step 6: Save & Next Steps

Write `approved.json` to `$_DESIGN_DIR/` (handled by the loop above).

If invoked from another skill: return the structured feedback for that skill to consume.
The calling skill reads `approved.json` and the approved variant PNG.

If standalone, offer next steps via AskUserQuestion:

> "Design direction locked in. What's next?
> A) Iterate more — regenerate from the approved direction with specific feedback
> B) Finalize — generate production Pretext-native HTML/CSS with /design-html
> C) Save to plan — add this as an approved mockup reference in the current plan
> D) Done — I'll use this later"

## Important Rules

1. **Never save to `.context/`, `docs/designs/`, or `/tmp/`.** All design artifacts go
   to `~/.vibestack/projects/$SLUG/designs/`. This is enforced. See DESIGN_SETUP above.
2. **Show variants inline, always.** Reading each PNG into the conversation is how
   the user sees the designs — there is no board to open in their browser.
3. **Confirm feedback before saving.** Always summarize what you understood and verify.
4. **Taste memory is automatic.** Prior approved designs inform new generations by default.
5. **Two rounds max on context gathering.** Don't over-interrogate. Proceed with assumptions.
6. **DESIGN.md is the default constraint.** Unless the user says otherwise.

{{include lib/snippets/askuserquestion-split.md}}
