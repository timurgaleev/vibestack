# TODOS

## Open

### Full-parity program (2026-06-21) — remaining

The session/preamble/tier-2 + binaries parity is shipped (v1.13.0–v1.15.0). The
one large remaining item:

- **Browse + design daemons (Phase E) — mostly done.** The browse shim has a
  `chain` verb (one-call sequences) AND a **persistent daemon** (`$B daemon &`)
  giving cross-call element refs (`snapshot` → `@e1`, then `click @e1` from a
  separate call) over a unix socket. Still remaining (need the upstream browser
  extension, genuinely large): `upload`, native `dialog` capture, cookie *import*
  from a real browser, and tunnel/pairing for `/pair-agent` +
  `/setup-browser-cookies`; plus the design-image daemon
  (CDP element refs, the browser extension, tunnels/pairing) and the design-image
  daemon are a multi-day vendoring project, not an in-session port. The four
  interaction-heavy skills (`/browse`, `/open-browser`, `/pair-agent`,
  `/setup-browser-cookies`) and `/design-*` mockups still degrade to text/shim
  until that lands. Effort: L. Priority: P2. Trigger: a decision to vendor the
  daemons.


### From v1.52–v1.58 upstream sync (2026-06-13)

Shipped: codex outside-voice **default-on** (plan-ceo/eng/devex-review + autoplan
master-switch + new `/document-release` doc-audit), mandatory **unresolved-decisions
verdict + blocking ExitPlanMode gate** (6 skills via 2 new snippets), **adversarial
defensive-testing framing** (`/ship` + `/review`), **scoped secret-scan** (modern
OpenAI key shapes in `/spec`, new pre-sink gate in `/ship` + `/cso` via
`lib/snippets/secret-scan-patterns.md`), **memex brain-preflight** in 5 planning
skills, and `${CLAUDE_SKILL_DIR:-…}` fallbacks for the safety hooks. Deliberately
DEFERRED (with reasons), revisit only on the stated trigger:

12. **make-pdf diagrams / multi-format / `/diagram` (upstream v1.58).** DEFERRED —
    vibestack's `/make-pdf` is a doc-only pointer to an unbuilt external binary; there
    is no renderer, no `print-css`, and no persistent browser tab in-repo. The upstream
    feature needs a real renderer + a 9.2MB vendored mermaid/excalidraw bundle + a
    rasterizing browser. Prerequisite: first vendor the actual make-pdf renderer.
    Until then, porting the `--to html|docx`, fence, image-directive, `--strict`, or
    emoji-fallback prose would document capabilities no in-repo binary provides.
    Effort: L. Priority: P3. Trigger: a decision to vendor the make-pdf renderer.

13. **Cross-session decision memory (upstream v1.57.5.0).** DEFERRED — redundant with
    memex-as-SSOT. Upstream's local `decisions.jsonl` event store reinvents what memex
    already does server-side (`entity_timeline`, `entity_recall`, hybrid search); a
    local copy would create a rival source of truth — the exact anti-pattern the
    single-brain policy avoids. If decision capture is ever wanted, the scoped move is a
    one-line instruction telling plan/ship to write decisions *to memex*, not a local
    store. Effort: M. Priority: P3. Trigger: explicit need for durable decision capture.

14. **Full brain-aware planning cache (upstream v1.52.1.0).** PARTIALLY ADDRESSED — the
    high-value gap (planning skills ignored the brain) is now closed with a lightweight
    `lib/snippets/brain-preflight.md` model-level memex query. The upstream heavy layer
    (`brain-cache` CLI + typed 8-kind schema-pack + TTL cache + resolvers) is NOT ported
    — it is bin infrastructure against the lightweight-skill-body philosophy. Effort: L.
    Priority: P3. Trigger: the prose preflight proving insufficient in practice.

15. **`${CLAUDE_SKILL_DIR}` render-time substitution (alternative to the `:-` fallback).**
    Shipped the low-risk shell-default fallback in the safety hooks + two body refs. A
    fuller fix would have `bin/vibe-render-skill` substitute the token with the actual
    per-target install dir at render time (covers Cursor/Kiro paths too, not just the
    `$HOME/.claude` fallback). Deferred because it complicates the `--check` drift
    semantics (a fresh render would differ from installed unless the substitution is
    parameterized by target). Effort: M. Priority: P3. Trigger: a Cursor/Kiro user
    hitting a hook-path miss, or CC dropping `${VAR:-default}` shell expansion.

16. **`/spec` Phase 4.5a Semantic Content Review (upstream).** DEFERRED (LOW) —
    an LLM-judgment pass over the drafted spec for named individuals, customers,
    NDA material, or unannounced strategy before filing the issue, with
    "proceed anyway" disabled on public repos. The existing regex redaction gate
    (Phase 4.5) + the new pre-filing re-scan are a partial backstop, so impact is
    bounded. Effort: S. Priority: P3. Trigger: a real semantic leak the regex
    gate misses.

### From v1.7.x upstream sync (2026-05-28)

Shipped v1.7.0–v1.7.2 (47 → 53 skills): `/spec`, the iOS preview suite, the
"5+ options — split, never drop" rule, the catalog-token trim, the
review/retro/deploy correctness guards, and `/ship` auto-closing the `/spec`
issue. Remaining follow-ups:

10. **iOS suite — REMOVED (v1.10.0).** The 5 iOS skills (`/ios-qa`, `/ios-fix`,
    `/ios-design-review`, `/ios-clean`, `/ios-sync`) and the bundled Mac-side
    daemon / DebugBridge templates / accessor codegen were removed — out of scope
    for this pack. Skill count 53 → 48.

11. **Broaden the AskUserQuestion split rule (optional).** The "5+ options —
    split, never drop" snippet is wired into the 4 `plan-*` skills +
    `/office-hours` (the genuine 5+ scope-decision surfaces). If `/qa`, `/ship`,
    or `/autoplan` start producing 5+ independent-option asks, add the
    `{{include lib/snippets/askuserquestion-split.md}}` directive there too.
    Effort: S.
    Priority: P3.
    Depends on: a real 5+ option ask surfacing in one of those skills.

### v1.5+ candidates from multi-target install eng review (2026-05-09)

Source design doc: `~/.vibestack/projects/vibestack/timurgaleev-main-design-20260509-101119.md` (APPROVED, multi-target install for Cursor + Kiro). Ship target: v1.4.0.

6. **`vibe certify` cross-runtime conformance harness** — a command
   that renders all 53 skills, installs into temp fixtures per target,
   runs smoke prompts, and prints a parity report
   (identical / soft-enforced / hard-enforced / broken). Codex
   outside-voice idea, validated independently. Turns "multi-target
   support" from a claim into a measurable badge; catches regressions
   when Cursor/Kiro change their spec.
   Effort: M (~3 days).
   Priority: P3.
   Depends on: v1.4 ship + a few months of real usage to know which
   conformance signals actually matter.
   **Related (shipped v1.7.4):** `bin/vibe-parity-audit` already covers the
   *upstream-parity* axis (do skills still mirror their source after a sync) —
   distinct from this *cross-runtime* axis (do they install/behave identically
   across Claude/Cursor/Kiro). The two could share a report format later.

7. **`./install --scope=user|project` flag** — install to project-local
   `.cursor/skills/` etc. instead of `~/.cursor/skills/`. Locks
   vibestack version per repo for teams that want pinned workflow.
   Needs clear `VIBESTACK_PROJECT_ROOT` convention to resolve `$PWD`
   ambiguity (the install runs from the cloned vibestack dir, not
   the user's project).
   Effort: S (~1 day).
   Priority: P3.
   Depends on: v1.4 ship + at least one user requesting it.

### v2 candidates from SKILL.md composition refactor (CEO review 2026-05-08)

Source design doc: `~/.vibestack/projects/vibestack/timurgaleev-main-design-20260508-205253.md` (APPROVED, mode HOLD).

1. **Migrate remaining shared sections to `lib/snippets/`** —
   Drift map (measured 2026-05-29):
   - **DONE (v1.7.3):** Review Readiness Dashboard — 5 byte-identical copies
     (`plan-ceo-review`, `plan-eng-review`, `plan-design-review`,
     `plan-devex-review`, `devex-review`) → `lib/snippets/review-readiness-dashboard.md`.
     Reconciled against upstream (identical modulo brand/stub adaptations);
     render-diff proved lossless. `ship` keeps its own richer 64-line variant.
   - **DRIFTED — need real reconciliation, NOT mechanical dedup:** `VIBESTACK
     REVIEW REPORT` (×6), `Plan File Review Report` (×6), `Review Log` (×5),
     `Spec Review Loop` (×2), `Plan Status Footer` (×6). Each copy carries
     genuine per-skill content (review dimensions, report fields), so a snippet
     would need `{SKILL_NAME}` + per-skill parameterization. The "Codex
     outside-voice fallback" is woven through the plan-* outside-voice flow, not
     a self-contained block.
   Effort: M (per drifted family, ~2-3 days each).
   Priority: P2.
   Depends on: nothing for the drifted families.

2. **Lint rules for `lib/snippets/`** — no duplicate headings, no
   runtime-execution instructions (a snippet should not contain
   "you must do X" runtime directives that conflict with the parent
   skill), max line count. Run as part of `./install --check`.
   Effort: S.
   Priority: P3.
   Depends on: v1 ship + at least 4 snippets in `lib/snippets/` so
   patterns are visible.

3. **Renderer infra-error fuzz tests** — PATH-shimmed mocks that
   force `mktemp`/`mv` to fail and assert exit 3 + clean error
   messages. Add iff a future refactor of error handling regresses
   silently (i.e., add reactively, not pre-emptively).
   Effort: S.
   Priority: P3.
   Depends on: nothing (can be done anytime if motivated).

5. **Lint rule for unbalanced markdown fences in skill sources** —
   v1's renderer uses minimal fence-state tracking (toggles `in_fence`
   on `^\`\`\``). An unbalanced fence in a skill source would silently
   swallow real directives. Add `./install --check` validation that
   walks each skill source and asserts even-numbered fence count.
   Catches the failure mode without adopting a markdown AST parser.
   Effort: S.
   Priority: P3.
   Depends on: v1 ship.

### From v1.5 install UX polish eng review (2026-05-10)

Source design doc:
`~/.vibestack/projects/vibestack/timurgaleev-main-design-20260510-182355.md`
(APPROVED, eng-review CLEARED with atomic-install pivot per Codex outside-voice).

9. **Detection heuristic refinement** — Codex outside-voice flagged that
   the v1.4.x detection check (`[ -d "$HOME/.${t}" ] || command -v "$t"
   >/dev/null 2>&1`) is a proxy, not real detection. An old uninstalled
   Cursor leaves `~/.cursor/`. A stale Homebrew binary on PATH isn't real
   detection. With v1.5's "Enter installs detected" default, false positives
   surprise users (`why did it install Cursor when I uninstalled it months
   ago?`). Tighten detection: app version metadata (e.g.,
   `~/.cursor/User/globalStorage/storage.json` recency), recent-mtime on
   target dir, or an interactive confirmation. OS-specific app-detection
   logic adds surface; defer until a real false-positive is reported.
   Effort: M (~1 day, target-by-target detection refinement).
   Priority: P3.
   Depends on: v1.5 ship + at least one user report.

## Completed

### Install UX polish + atomic install — shipped in v1.5.0 (2026-05-10)

Driven by `/office-hours` (TODO #8 source design), refined through `/plan-eng-review`
with a Codex outside-voice that produced a strategic pivot from fail-soft polish
to per-target staged/atomic install. v1.5.0 closes both deferred items.

Source design doc: `~/.vibestack/projects/vibestack/timurgaleev-main-design-20260510-182355.md`
(APPROVED, 8.5/10 spec-review, ENG-REVIEW CLEARED with 17 resolutions).

1. **`./install` auto-detect + interactive prompt + per-target progress UX** (was Open #8).
   Shipped as the install plan + Enter UX: write plan listing each target's path
   and detection status, single prompt with `Enter / a / e / d / q` branches,
   per-target counter (`installing 46 skills... done (46/46)`), `Installation
   complete:` / `Installation incomplete:` outcome headers, fail-summary with
   ✓/✗ per target. Hook warning preserved on partial success (R15 — Codex
   outside-voice catch).
2. **`./install --staged` (atomic stage-and-swap)** (was Open #4). Implemented
   inline as the v1.5 default — every install renders to
   `~/.<target>/skills.staging.<pid>/` then atomically swaps via
   `mv skills{,.old}` + `mv staging skills`. Per-target atomicity. Recovery
   pass cleans orphaned `.staging` dirs and restores from `.old` on power-failure
   detection. No separate `--staged` flag needed; the behavior is the default.
3. **PTY test harness + 15 integration tests.** `test/pty-run.py` (Python `pty`
   module) exercises TTY-gated install paths; new tests cover prompt branches,
   atomic-swap, staging-failure preservation, recovery, SIGINT.
4. **Bash 4+ now enforced** with a `BASH_VERSINFO` guard at install start
   (de facto since v1.4.0; v1.5.0 surfaces it explicitly with a Homebrew hint).
5. **SIGINT/SIGTERM trap** with separate exit codes (130 for INT, 143 for TERM
   per Codex outside-voice; the design's original `INT TERM → 130` was wrong).

### DX Review — shipped in v1.2.0 (2026-05-03)

Driven by `/plan-devex-review` (target: Champion-tier TTHW for the OSS-contributor persona) and refined by a Codex cross-model challenge that dropped 2 items and reframed 4. Net: 12 of 14 considered, 12 delivered, 2 dropped.

1. README rewrite — `Try /office-hours in 30 seconds` section with rendered terminal output. Magical-moment delivery in the README itself.
2. README — `By workflow` navigation table mapping 6 use-cases to skill chains.
3. ~~`QUICK_TOUR.md`~~ — **dropped per Codex review** (more docs ≠ shorter TTHW; README is the single proof path).
4. ~~`COOKBOOK.md`~~ — **dropped per Codex review** (same reason; "By workflow" table covers it).
5. README — `## More` section linking ETHOS, CHANGELOG (with `### Removed` anchor), CONTRIBUTING, docs/skills.md, docs/external-tools.md, LICENSE.
6. Hook decision logging — `skills/careful/bin/check-careful.sh` and `skills/freeze/bin/check-freeze.sh` log decisions only when `VIBESTACK_DEBUG=1`. Subshell-isolated, `flock`-guarded, atomic-rename rotation at 1MB. 8/8 tests pass.
7. `.github/ISSUE_TEMPLATE/bug.yml` — structured bug report with repro, env, vibestack version, OS.
8. `.github/ISSUE_TEMPLATE/skill-proposal.yml` — enforces ETHOS "would you reach for this once a week?" + overlap check.
9. `.github/pull_request_template.md` — pre-flight checklist (install runs, brand audit, skill count consistency, frontmatter sanity, hook test).
10. `bin/vibe-skill-track` — opt-in UserPromptSubmit hook logging explicit `/skill` invocations to `~/.vibestack/analytics/skill-usage.jsonl`. Off by default. Documented limitation: auto-invokes not captured (Claude Code has no `SkillStart` event).
11. `install` summary — replaced verbose 46-line skill list with a focused footer ("Installed 46 skills → ~/.claude/skills. Try /office-hours first.").
12. README — `What ./install modifies on your machine` block (path-by-path, symlink-vs-copy, idempotency note).
13. `uninstall` truth — removes ALL skill symlinks (not just SKILL.md), `vibe-*` binaries, prompts before deleting `~/.vibestack/` state, prints what stays. `--delete-state` flag for non-interactive use; ordering fixed so the flag bypasses the prompt entirely.
14. `docs/external-tools.md` — honest disclosure that vibestack does not bundle the browse daemon or `vibe-model-benchmark`. Rewrote 5 SKILL.md NEEDS_SETUP blocks and 3 docs/skills.md descriptions to point here instead of the non-existent `./setup`.

**Verification artifacts:**
- All hook tests pass (8 careful+freeze, 6 vibe-skill-track).
- `install` + `uninstall` round-trip tested in isolated `$HOME`.
- Brand audit clean (zero hits across `skills/`, `docs/`, `README.md`, `TODOS.md`, `CHANGELOG.md`).
- Skill count consistent (46 across `skills/`, README, docs/skills.md).
