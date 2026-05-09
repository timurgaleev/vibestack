# TODOS

## Open

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

4. **`./install --staged` (atomic stage-and-swap)** — surface from
   eng review's Codex pass: v1 install is best-effort
   (per-file atomic mv, but per-run partial). For users on shared
   CI infra or shared workstations who need true all-or-nothing
   install, add `./install --staged`: render all 46 skills to
   `~/.claude/skills.staging/`, then `mv ~/.claude/skills{,.old}`
   and `mv ~/.claude/skills.staging ~/.claude/skills`. Edge case:
   power failure mid-rename leaves `.old` behind; recovery on next
   run.
   Effort: M (~30 lines + power-failure handling).
   Priority: P3.
   Depends on: v1 ship.

5. **Lint rule for unbalanced markdown fences in skill sources** —
   v1's renderer uses minimal fence-state tracking (toggles `in_fence`
   on `^\`\`\``). An unbalanced fence in a skill source would silently
   swallow real directives. Add `./install --check` validation that
   walks each skill source and asserts even-numbered fence count.
   Catches the failure mode without adopting a markdown AST parser.
   Effort: S.
   Priority: P3.
   Depends on: v1 ship.

## Completed

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
