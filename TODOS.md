# TODOS

## Open

### v1.5+ candidates from multi-target install eng review (2026-05-09)

Source design doc: `~/.vibestack/projects/vibestack/timurgaleev-main-design-20260509-101119.md` (APPROVED, multi-target install for Cursor + Kiro). Ship target: v1.4.0.

6. **`vibe certify` cross-runtime conformance harness** — a command
   that renders all 46 skills, installs into temp fixtures per target,
   runs smoke prompts, and prints a parity report
   (identical / soft-enforced / hard-enforced / broken). Codex
   outside-voice idea, validated independently. Turns "multi-target
   support" from a claim into a measurable badge; catches regressions
   when Cursor/Kiro change their spec.
   Effort: M (~3 days).
   Priority: P3.
   Depends on: v1.4 ship + a few months of real usage to know which
   conformance signals actually matter.

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
   Codex outside-voice fallback (×9), Review Readiness Dashboard (×6),
   Spec Review Loop (×2). Each needs a per-section drift-reconciliation
   pass (same methodology as v1 Day 0). Defer until v1 ships and the
   render pipeline is proven on `capture-learnings` + `prior-learnings`.
   Effort: M (per snippet, ~3 days).
   Priority: P2.
   Depends on: v1 ship.

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
