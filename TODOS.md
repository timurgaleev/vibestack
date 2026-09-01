# TODOS

## Open

Nothing open.

## Completed

### Evidence, version, detach and probe helpers (2026-09-01)

The four items that could not be written as skill text because the mechanism
did not exist. Each is a binary now, with both directions asserted in
`test/test-evidence-bins.sh` (63 cases).

A cross-model review of the first draft found eleven ways a gate could wrongly
pass. Each confirmed one is fixed and carries a test; two claims were refuted by
running them and left alone.

- **`vibe-tree-hash`** answers "has the content changed?" where a commit count
  cannot. It copies the real index into a throwaway one, refreshes it against
  the working tree, and returns the resulting git tree id, so a rebase, an
  amend or a commit of already-written content leaves the fingerprint identical
  while an uncommitted edit moves it. Two earlier constructions were wrong:
  hashing the HEAD tree id together with `git diff HEAD` failed the commit
  case, and seeding from HEAD made a staged-but-uncommitted file invisible, so
  editing it moved nothing. Scope limits are documented in the header:
  submodule content and git's own line-ending/exec-bit normalisation are not
  visible, because the identity is what git would record.
- **`vibe-evidence`** records the command, its exit status, the tree hash it ran
  against, and the repo it ran in. `check` takes the MOST RECENT matching
  record -- an older pass must not outlive the failure that supersedes it --
  and fails on a missing ledger, an unfingerprintable tree, or any unreadable
  line, since corruption is the one thing that may never fail open. Command
  output is never stored: unbounded, and the likeliest place for a token to
  appear. A command line carrying a high-confidence secret is refused outright.
- **`vibe-version-bump`** moves VERSION, `package.json`, `package-lock.json` and
  `npm-shrinkwrap.json` (including the `packages[""]` self-entry) together, and
  takes `--root` for a manifest in a subdirectory. Symlinked targets are
  resolved so the link survives and its target changes; each file keeps its own
  mode; the temp name carries the pid so two concurrent bumps cannot rename
  each other's bytes into place. Every file is parsed and staged before any is
  written, and a rename failing partway is rolled back. A SIGKILL between two
  renames is not survivable -- there is no transaction across files -- and the
  header says so.
- **`vibe-detach`** runs a command past the turn boundary and records its output
  and exit status. `status` distinguishes running (exit 2) from failed (exit 1);
  conflating them reports a running job as a failure. The job records its own
  pid, because `setsid` forks when the caller is already a process group leader
  and the launcher's `$!` would then name a process that exits at once. The
  command is written as a bash array, not a `printf %q` command line: an
  assignment-shaped first word would otherwise be read as a variable assignment
  and the intended program would never run while the job reported success.
- **`vibe-codex-probe`** replaces `codex --version` as an availability check,
  which succeeds while logged out. Cheapest negatives first (no binary, then a
  cached verdict, then no credentials anywhere), and only then the paid round
  trip. `usable` requires an actual reply, not just exit 0 -- a wrapper that
  exits without contacting anything is not usable. The cache is keyed to the
  credential context it was taken in, so a verdict cannot outlive the
  credentials it was about, and a corrupt or unkeyed cache is ignored.

`install` picks all five up through its existing `bin/vibe-*` glob.

Still not a gap: the PR-body secret scan cannot move to `vibe-redact`, which
installs a pre-push hook and whose scanning half reads a pushed diff rather than
arbitrary text. The prose scan over the exact bytes about to be published stays.

### Renderer infra-error coverage + doc accuracy (2026-08-18)

Shipped in **v1.33.1**. Closes both remaining P3 items, and the fuzz tests found a
real bug while being written.

**`bin/vibe-render-skill` had one unguarded `mv`.** Every other infra failure exits 3
with a clean message; `mv "$SUB_TMP" "$TMP"` after `${CLAUDE_SKILL_DIR}` substitution
did not. On failure the renderer reported success while the caller got a
half-substituted file, and `SUB_TMP` — absent from the cleanup trap — was left behind
in the destination directory. Both fixed: the move is guarded, and `SUB_TMP` joins the
trap.

**Fuzz tests.** `test/fixtures/render/13-infra-errors/` PATH-shims `mktemp` and `mv`
to force failure and asserts exit 3, the exact stderr line, destination contents, and
that no temp file leaks. Six cases, covering every guarded infra path reachable that
way. Each was mutation-tested: neutering a guard flips exactly its own case and no
other. The one guard left uncovered (`skill-dir substitution failed`, needs a failing
`python3`) is noted in the fixture README.

**`${CLAUDE_SKILL_DIR}` list derived mechanically.** The audit doc claimed 6 skills.
The real number is **19** — the token usually arrives through an `{{include}}`d
snippet (`browse-detect` / `browse-setup` reference `../browse/bin/vibe-browse`), so a
skill's own source cannot be grepped for it. The doc now carries the correct list, the
corrected per-skill matrix column, and the sentinel-render command that regenerates it,
so the next person re-derives instead of hand-editing.

**Track B claims reconciled.** `docs/external-tools.md` called Kiro hooks "pending
verification" while the audit recorded Track B as completed on 2026-05-09. The audit
was right; external-tools now states what Track B actually found — on both Cursor and
Kiro hook-bearing skills install but their hooks do not fire, and only Cursor has a
native sandbox behind them.

Suites: render 22/0, install-integration 33/0, source-lint 8/0, vibe-bins 18/0,
certify 2/0 plus 4/4 targets PASS.
**Completed:** v1.33.1 (2026-08-18)

### Codex CLI is a default target (2026-08-17)

Shipped in **v1.33.0**. `codex` installs into the paths Codex documents and joins
`ALL_TARGETS`, so `./install`, `--target=all` and `--yes` all cover four runtimes.

Evidence for the path (the earlier `~/.codex/skills` was never documented):
- Current OpenAI docs: user skills `$HOME/.agents/skills`, repo skills
  `.agents/skills`, admin `/etc/codex/skills`, plus OpenAI's bundled system set.
- Sentinel experiment on codex-cli 0.147.0: a fresh Codex process listed probe
  skills planted in **both** `~/.agents/skills` and `~/.codex/skills`. The old
  path worked, but on undocumented behavior.
- `~/.agents/` is also the plugin-marketplace root
  (`~/.agents/plugins/marketplace.json`) — skills and plugins share the tree.

What shipped:
- **A target name is no longer a directory name.** Three maps instead of one:
  `TARGET_CONFIG_DIR` (detection only — `~/.codex` for codex), `TARGET_ROOT`
  (user scope — `~/.agents/skills`), `TARGET_PROJECT_REL` (project scope —
  `.agents/skills`). The project-scope loop reads the registry instead of
  deriving `.<target>/skills` from the name, and `target_detected` reads the
  config-dir map, so `$CODEX_HOME` no longer reads as absent.
- **`prune_legacy_root`** removes **our own skill names** from a superseded root
  (`TARGET_LEGACY_ROOT`). Codex scans both roots, so a leftover copy would list
  every skill twice and never update. The root itself is never touched — Codex's
  bundled `.system/` and anyone else's skills stay.
- `uninstall` mirrors the mapping (`.agents/skills` for codex, four-target
  `all`). `bin/vibe-certify` too — it derived the same path from the name.
- Docs corrected: `docs/external-tools.md` (which listed Codex as "not yet a
  target"), `CLAUDE.md`, the audit doc's Codex caveat, and the README's claim
  that Codex users type `/command` — Codex uses `$name` and `/skills`.
- Hook warning now names Codex alongside Cursor/Kiro.

New tests: `codex installs to .agents/skills, prunes legacy root` (our stale copy
goes, `.system/` and an unrelated skill stay) and `codex project scope uses
.agents/skills`. Dry-run, non-TTY default set, per-skill byte-identity and the
`e` per-target prompt all cover four targets now.

Codex Track B stays unverified: `$name` / implicit invocation, helper symlinks,
`hooks:` failing safely, and whether all 52 descriptions survive Codex's
initial-list budget (2% of context or 8,000 chars, after which it shortens
descriptions and may omit skills). `uninstall` still hardcodes its target list
rather than sharing the registry — a real inconsistency, not a blocker.

Suite: 33 passed, 0 failed. `vibe-certify`: 4/4 targets PASS.
**Completed:** v1.33.0 (2026-08-17)

### Install no longer deletes skills it does not own (2026-08-17)

**Data loss, reproduced before and after.** The atomic swap replaced a target's
whole `skills/` root with the staged tree, which holds only vibestack skills.
Every other entry in that root was carried off to `.old` and deleted by the next
run's recovery pass. Two concrete victims:

- A runtime's own bundled skills. Codex keeps its system set in
  `<root>/.system/` — the exact directory we would install alongside.
- The clone path README documents (`~/.claude/skills/vibestack`). The swap moved
  the checkout aside, left the generated symlinks pointing at the vanished path,
  then deleted the checkout on a later run.

Fix: `adopt_foreign_entries` moves everything that is not one of our own skill
names back into the live root, called after a successful swap, before the
pre-swap `.old` purge, and in the recovery pass before a stale `.old` is
removed — so an interrupted run still recovers. Ownership is derived by
`vibestack_owned_names` exactly as `install_skill_to_target` derives names, so
the two cannot disagree. Dotfiles are included; the live root wins on a name
clash.

Also in this change:
- `test_install_atomic_swap_on_success` asserted the opposite property (an
  unrelated root-level sentinel had to be **deleted** for the test to pass) — it
  now checks that leftovers inside *our own* skill dirs are replaced, and the new
  `test_install_preserves_foreign_skills` locks the ownership boundary. The
  nested-checkout test now asserts the checkout survives two runs.
- The suite stopped overwriting the tracked `bin/vibe-render-skill`: install
  reads a `$VIBE_RENDER_SKILL` seam and the fail-injection stub is written to a
  gitignored path, so a hard-killed run can no longer leave the tracked renderer
  replaced (and the `git checkout --` self-heal is gone).
- Renderer test debt from v1.29.0 closed. The stub read `src="$1"; dst="$2"`
  while install passes `--skill-dir DIR SOURCE DEST`, so it failed *every* skill
  instead of the one it targeted. The two byte-identical tests assumed one
  rendering for all targets; per-target substitution makes that false. Detection
  is now a sentinel render (the token often arrives via an `{{include}}`d
  snippet, so the skill source cannot be grepped for it), and per-target skills
  are compared against a render made with their own `--skill-dir` plus a
  no-unresolved-token assertion.

Suite: 31 passed, 0 failed (was 26/4 — those 4 were red on `main` before this
change). `vibe-certify`: 4/4 targets PASS.
**Completed:** 2026-08-17

### make-pdf renderer vendored (TODOS #12) — shipped in v1.32.0 (2026-08-03)

12. **make-pdf is a real renderer now.** `make-pdf/{src,test}` vendored and
    adapted (13 TS modules on bun: marked pipeline, print CSS, Paged.js flow
    via the browse daemon, image policy/sizing, smartypants, pdftotext
    verification, docx/html output). `bun run build:make-pdf` compiles
    `make-pdf/dist/pdf`; `skills/make-pdf/bin/vibe-make-pdf` launcher prefers
    the binary, falls back to bun. Suite: 194 tests (unit + e2e gates against
    the bun browse launcher). End-to-end verified: markdown → PDF renders.
    v1.32.1 completes it: `lib/diagram-render` (mermaid + excalidraw bundle)
    vendored — all e2e gates run (9/9), mermaid→PDF verified end to end.
    **Completed:** v1.32.0 + v1.32.1 (2026-08-03)


### `vibe certify` (TODOS #6) — shipped in v1.31.0 (2026-08-02)

6. **Cross-runtime conformance harness.** `bin/vibe-certify [targets…]`
   installs the full pack into a throwaway fixture per target via the real
   `./install --scope=project` path and verifies every skill: frontmatter
   name, no unexpanded includes, no leftover `${CLAUDE_SKILL_DIR}` tokens,
   symlinks resolve, full skill count. PASS/FAIL matrix, exit-code gated;
   `test/test-certify.sh` covers clean + fail-closed paths. Live smoke prompts
   stay in `bun run test:evals`. Current: 4/4 targets PASS.
   **Completed:** v1.31.0 (2026-08-02)

### Closed by design (2026-08-02)

14. **Full brain-aware planning cache** — RESOLVED as designed: the
    lightweight `brain-preflight` snippet IS the intended mechanism; the heavy
    cache layer is rejected as bin infrastructure against the
    lightweight-skill-body philosophy. Reopen only if the prose preflight
    proves insufficient in practice.
10. **iOS suite** — removed in v1.10.0; out of scope for this pack. Record
    kept here for history.


### Shared-section dedup (TODOS #1) — shipped in v1.30.0 (2026-08-02)

1. **Drifted-family migration resolved.**
   - `lib/snippets/plan-file-review-report.md` — the Plan File Review Report +
     VIBESTACK REVIEW REPORT section, deduped from 5 skills (plan-ceo/eng/
     devex/design-review + devex-review). The byte-identical trio renders
     unchanged (proven by render-diff); plan-design-review and devex-review
     picked up the two fixes their copies had missed (verdict-line wording,
     delete-then-append write flow). `/codex`'s compact variant stays
     intentionally separate. The nested unresolved-decisions-status include is
     inlined in the snippet (renderer allows one level); the standalone
     snippet file remains for `/codex`.
   - `lib/snippets/spec-review-loop.md` — deduped from `/office-hours` +
     `/plan-ceo-review` via `{SKILL_NAME}` (renders byte-identical for both).
   - **Plan Status Footer** — only one real copy exists (autoplan); the other
     grep hits are skip-list bullets. No dedup needed.
   - **Review Log** — permanently per-skill BY DESIGN: each copy carries a
     different vibe-review-log payload schema (metrics, STATUS rules, MODE
     enums) consumed by vibe-review-read and the dashboards; a shared snippet
     would break the data contract. Do not re-attempt mechanical dedup.
   **Completed:** v1.30.0 (2026-08-02)


### Install family — shipped in v1.29.0 (2026-08-02)

- **#15 `${CLAUDE_SKILL_DIR}` render-time substitution** —
  `vibe-render-skill --skill-dir <dir>` replaces both the bare token and the
  `:-fallback` form with the concrete per-target install path; `./install`
  passes the production path during staged renders, so hooks and body commands
  resolve correctly on every runtime (fixes the bare-token refs too).
- **#9 Target-detection refinement** — a stale `~/.cursor/`-style dir no
  longer counts as detected: CLI on PATH, or home dir with activity in the
  last 180 days. `VIBE_TEST_MODE` seam unchanged.
- **#7 `./install --scope=user|project`** — project-local installs into
  `<project-root>/.claude|.cursor|.kiro/skills` (pins the pack per repo);
  `--project-root`/`$VIBESTACK_PROJECT_ROOT` resolve the root, self-install
  into the pack's own checkout is refused, runtime bin/state stay global.
  `./uninstall` mirrors the flags. Verified round-trip: 52 skills in, hook
  paths substituted, uninstall leaves zero.
  **Completed:** v1.29.0 (2026-08-02)

### Quick-win closeout — shipped in v1.28.0 (2026-08-02)

- **Browse + design daemons (Phase E) — COMPLETE.** Everything the old open
  block listed is shipped: persistent daemon + `chain` (v1.17.0/v1.16.0),
  upload/dialog/cookies incl. import from the encrypted browser store
  (`browse/src/cookie-import-browser.ts`, picker UI + `--domain` direct mode),
  tunnels/pairing (ngrok), design mockups (`vibe-design`), sidebar extension +
  full TS daemon (v1.24.0), JS stealth layer (v1.19.0). No native browser-patch
  work remains in scope.
- **#13 Cross-session decision memory** — implemented as
  `vibe-decision-log` / `vibe-decision-search` (event-sourced local
  `decisions.jsonl`); memex stays the semantic-recall layer.
- **#16 `/spec` Phase 4.5a Semantic Content Review** — LLM-judgment pass over
  the final draft (named individuals, customer names, unannounced strategy,
  NDA material, codename bleed) with `SEMANTIC_REVIEW:` marker,
  public-repo-strict options, injection hardening; regex gate renamed 4.5b and
  stays the deterministic backstop.
- **#11 AskUserQuestion split rule** — `askuserquestion-split` snippet now also
  included in `/qa`, `/ship`, `/autoplan`.

### E2E skill-eval harness v1 — shipped in v1.27.0 (2026-08-02)

17. **End-to-end skill evals.** `test/evals/session-runner.ts` spawns real
    `claude -p` sessions in a sandbox (temp git project + project-level
    `.claude/skills/` rendered from repo sources, VIBESTACK_HOME isolated),
    streams NDJSON, and survives timed-out children that leave pipe-holding
    orphans (reader cancel + stderr race, regression-locked by
    `session-runner-timeout.test.ts` — offline, always runs). Smoke evals for
    `/review`, `/ship`, `/investigate` assert skill-specific vocabulary;
    opt-in via `bun run test:evals` (costs real tokens).
    **Completed:** v1.27.0 (2026-08-02)

### Source lint (TODOS #2 + #5) — shipped in v1.27.0 (2026-08-02)

2./5. **`bin/vibe-lint-sources`** — fence balance across skill sources and
    snippets, snippet rules (no duplicate headings, no nested `{{include}}`,
    max 400 lines). Runs inside `./install` before rendering (fail fast) and
    in `test/test-source-lint.sh` (7 cases). The "no runtime-execution
    directives" idea from #2 was dropped — not mechanically lintable without
    heavy false positives.
    **Completed:** v1.27.0 (2026-08-02)

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
