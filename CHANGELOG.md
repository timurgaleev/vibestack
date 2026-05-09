# Changelog

## 1.4.1 — 2026-05-09

Docs-only patch. Closes the gap between the v1.4.0 tag and the merged
state on main: the `a0e5b52` Track B verification commit landed after
v1.4.0 was tagged but before the PR merged, so `git checkout v1.4.0`
shipped the pre-verification ("pending Track B") version of the audit
doc. This patch re-tags so the v1.4.x release matches what's actually
on main.

### Changed
- No code changes. Docs only.
- v1.4.0 → v1.4.1: `git checkout v1.4.1` now matches the merged main
  state, including the Track B verification section in
  `docs/agent-skills-compatibility-audit.md`, the empirical per-target
  table in README, and the Kiro-no-sandbox warning in CHANGELOG notes.

## 1.4.0 — 2026-05-09

Multi-target install: vibestack now installs into Cursor and Kiro alongside
Claude Code, all from a single source. Same SKILL.md, three folders. Built on
the Agent Skills open standard ([agentskills.io](https://agentskills.io/specification))
which Claude Code, Cursor (`~/.cursor/skills/`), and Kiro (`~/.kiro/skills/`)
all implement. No format translation, no per-target writers — the spec already
guarantees portability at the file-shape layer.

### Added
- `./install --target=<list>` — install into one or more agents.
  Accepts `claude`, `cursor`, `kiro`, `all`, or any comma-separated subset.
- `./install` (interactive default) — TTY mode prompts per-target with Y default.
  Three separate Y/n prompts so you opt into each agent independently.
- `./install --yes` / `-y` — non-interactive shorthand for `--target=all`.
- `./install --dry-run` — preview the 138 outputs (46 skills × 3 targets) without
  writing any files. Composes with `--target=`.
- `./uninstall --target=<list>` — symmetric multi-target removal.
- `docs/agent-skills-compatibility-audit.md` — full per-skill compatibility
  matrix from Day 0 spec audit (all 46 skills are spec-compliant on file
  shape; 4 hook-bearing skills flagged for runtime verification).
- `docs/hook-verification.md` — manual procedure for verifying hooks fire
  correctly under Cursor and Kiro per (target × skill).
- `test/test-install-integration.sh` — 13 integration tests covering
  regression (Claude byte-identical), multi-target install, dry-run,
  idempotency, install/uninstall round-trip, hook warning, bin symlinks.

### Changed
- **BREAKING for CI users:** `./install` with no flags now defaults to
  installing into ALL THREE targets (claude + cursor + kiro). v1.3.x default
  was claude-only. CI scripts that want claude-only behavior must now pass
  `--target=claude` explicitly. Interactive (TTY) usage is unaffected — you
  get prompted per target.
- `./install` and `./uninstall` switched from `set -e` to `set -uo pipefail`
  with explicit error handling per critical operation. Per-target failures
  surface clearly without silent abort mid-loop.
- The per-skill install body was extracted into `install_skill_to_target()`
  (Beck refactor — make the change easy first, then make the easy change).
  Same logic, parameterized destination root.
- `bin/vibe-render-skill` is **unchanged** from v1.3.0. Multi-target reuses
  the v1.3.0 renderer 1:1.
- `lib/snippets/` is **unchanged**. Same snippets compile to identical
  SKILL.md content for all three targets.
- All 46 `skills/<n>/SKILL.md` source files are **unchanged**.

### Notes
- For hook-bearing skills (`careful`, `freeze`, `guard`, `investigate`),
  Cursor and Kiro support is **soft tier — verified empirically** against
  Cursor `2026.05.07-42ddaca` and Kiro CLI `2.2.2`. The `PreToolUse` hook
  command does NOT fire in either target (Cursor uses `${skillDir}`, Kiro
  doesn't expose a `${CLAUDE_SKILL_DIR}` equivalent at all). The install
  prints a one-line warning when these skills are installed into non-Claude
  targets.
- ⚠️ **Cursor's native shell sandbox** blocks `rm -rf` and similar dangerous
  commands independently of our hook, so Cursor users get fallback safety.
  **Kiro has no equivalent sandbox** — `rm -rf` ran without any prompt
  during Track B testing. If safety skills are load-bearing for you, use
  Claude Code (hard tier) or be aware of the gap.
- Full per-target tier matrix and Track B test results in
  `docs/agent-skills-compatibility-audit.md`. Re-verification procedure
  for future Cursor/Kiro versions in `docs/hook-verification.md`.
- v1.4.0 designed by `/office-hours` + `/plan-eng-review` + Codex outside-voice
  cross-model challenge. Track B verified end-to-end before merge.

## 1.3.0 — 2026-05-09

SKILL.md composition pipeline. Shared markdown sections now live in
`lib/snippets/` and are expanded into installed `SKILL.md` files via a
tiny `{{include lib/snippets/X.md}}` directive resolved at install time.
Designed by `/office-hours` + `/plan-ceo-review` + `/plan-eng-review`.

### Added
- `bin/vibe-render-skill` — install-time markdown renderer. Expands include
  directives, substitutes `{SKILL_NAME}` per skill, writes a sidecar
  `.vibe-render.json` metadata file, supports `--check` mode, idempotent.
  ~150 lines bash 3.2-portable; uses `set -euo pipefail`, atomic
  `mktemp`+`mv`, signal trap for cleanup. Exit codes: 0 success / 2 validation
  / 3 infrastructure.
- `lib/snippets/capture-learnings.md` — canonical "Capture Learnings"
  block. Used in 14 skills (cso, design-consultation, design-review,
  plan-ceo-review, plan-eng-review, qa, retro, ship, devex-review,
  office-hours, plan-design-review, plan-devex-review, qa-only,
  investigate). 8 other skills retained inlined variants per Day 0
  drift audit (4 short-form, 4 domain-customized).
- `lib/snippets/prior-learnings.md` — canonical "Prior Learnings"
  search block. Used in 14 skills (all skills that previously had it).
- `test/fixtures/render/` — 11 fixtures covering byte-identical
  fallback, single/multi include, missing/nested include rejection,
  fence-state tracking (codefenced and indented directives stay literal),
  no-frontmatter handling, idempotency, --check mode (drift detected /
  no drift), and arg parsing (5 invalid invocations).
- `test/test-render-skill.sh` — fixture-driven harness; 16 test cases
  pass on first run.

### Changed
- `./install` — `SKILL.md` no longer symlinked; rendered into a regular
  file via `vibe-render-skill`. `bin/` and per-skill sub-doc symlinks are
  unchanged. Renderer invoked via absolute repo path so a fresh install
  works before `$VIBE_BIN` exists.
- `./uninstall` — patched to remove regular-file `SKILL.md` and
  `.vibe-render.json` sidecar at canonical paths. Existing
  symlink-removal loop unchanged. User-placed regular files at other
  paths are still preserved.
- 28 skills migrated (14 each for capture-learnings and prior-learnings;
  13 skills got both). Total: 874 lines removed from sources;
  installed-output content unchanged for 40 of 46 skills (byte-identical
  P3 baseline). 6 skills harmonize +2 trailing blank lines as predicted
  by the Day 0 drift audit (purely whitespace, LLM-invisible).

### Architecture
- Render-at-install treats SKILL.md authoring as a build step rather
  than verbatim source. Skill authors can now keep shared logic in one
  place and reference it via include directives.
- `{SKILL_NAME}` token substitution is the v1's only renderer-side
  variable — narrowly scoped, not a general templating system.
- `.vibe-render.json` sidecar replaces an inline HTML-comment header
  (which would have leaked into LLM prompt content). Sidecars are
  LLM-invisible and tool-readable.
- Code-fence state tracking prevents directive expansion inside ```
  blocks, so skills can document the include syntax without triggering
  it.

### Verified
- `bash -n` syntax check on renderer + install + uninstall.
- 16 fixture tests pass (`bash test/test-render-skill.sh`).
- P3 baseline: 46 source skills install with the expected output diff
  pre-vs-post migration (0 unintended changes, 6 expected
  whitespace-only harmonizations).
- Round-trip: `./install` then `./uninstall` against fresh `$HOME`
  leaves zero residual files in `~/.claude/skills/<name>/`.

---

## 1.2.1 — 2026-05-03

`/ship` now auto-tags and auto-publishes a GitHub/GitLab Release. No more manual `gh release create` after every merge.

### Changed
- `skills/ship/SKILL.md` — three additions:
  - **Step 15.2** — annotated-tag the version-bump commit (`v$NEW_VERSION`). Idempotent: skips if already at HEAD, moves if at a different commit, creates if absent.
  - **Step 17** — `git push -u origin <branch> --follow-tags` so the new tag goes up with the branch (plus an explicit fallback push if the branch was already pushed).
  - **Step 19.5** — extract the CHANGELOG section for the new version and create (or update) a GitHub/GitLab Release pointing at the tag. Idempotent — re-running `/ship` updates the notes instead of erroring.
- Documents the merge-strategy tradeoff: tags placed on the feature branch survive merge-commits; squash-merges orphan the tag and need a manual re-tag against `main`.

### Notes
- This is the only `/ship` run since `/ship` was modified — the tag and release for v1.2.1 itself need to be created manually (or by re-running `/ship` once the merged change is on main, since Step 19.5 is idempotent).

---

## 1.2.0 — 2026-05-03

DX overhaul driven by `/plan-devex-review` + Codex outside-voice. Champion-tier TTHW target for an OSS contributor cloning vibestack from GitHub.

### Added
- `/tdd` — test-driven development with vertical-slice red-green-refactor loop. Tests verify behavior through public interfaces (so they survive refactors); anti-pattern callout for horizontal slicing; per-cycle checklist. Sub-docs: `deep-modules.md`, `interface-design.md`, `mocking.md`, `refactoring.md`, `tests.md`.
- `/improve-arch` — find deepening opportunities in an existing codebase: turn shallow modules into deep ones (small interface, deep implementation) for testability and AI-navigability. Precise glossary (module, interface, depth, seam, adapter, leverage, locality); deletion test; explore → present candidates → grilling loop. Optional `CONTEXT.md` and `docs/adr/` integration. Sub-docs: `DEEPENING.md`, `INTERFACE-DESIGN.md`, `LANGUAGE.md`.
- README — `Try /office-hours in 30 seconds` magical-moment section with rendered terminal output (Stripe-style inline receipt).
- README — `By workflow` navigation table mapping 6 use-cases to skill chains.
- README — `What ./install modifies on your machine` table for install-trust transparency.
- README — `Data written locally` disclosure section (no telemetry; documents `~/.vibestack/projects/`, `~/.vibestack/analytics/`, `~/.vibestack/hook.log`, `~/.vibestack/freeze-dir.txt`).
- `docs/external-tools.md` — honest disclosure that vibestack does not bundle the browse daemon or `vibe-model-benchmark`. Affected 5 SKILL.md NEEDS_SETUP blocks and 3 `docs/skills.md` descriptions rewritten to point here instead of the non-existent `./setup`.
- `bin/vibe-skill-track` — opt-in UserPromptSubmit hook that logs explicit `/skill-name` invocations to `~/.vibestack/analytics/skill-usage.jsonl`. Off by default; user wires it into `~/.claude/settings.json`. `VIBESTACK_TRACK=0` disables. Auto-invokes not captured (Claude Code does not expose a `SkillStart` event — limitation documented).
- `.github/ISSUE_TEMPLATE/bug.yml`, `.github/ISSUE_TEMPLATE/skill-proposal.yml`, `.github/pull_request_template.md` — community contribution scaffolding.

### Changed
- `install` — final-line output replaced ("Installed N skills → ~/.claude/skills. Try /office-hours first.") and the verbose 46-line skill list removed (was noise on every re-install).
- `uninstall` — now removes ALL skill symlinks (not just `SKILL.md`), removes `vibe-*` binary copies, prompts before deleting `~/.vibestack/` state, prints what stays. Added `--delete-state` flag for non-interactive runs.
- `skills/careful/bin/check-careful.sh`, `skills/freeze/bin/check-freeze.sh` — added opt-in `_vibestack_log` decision audit (controlled by `VIBESTACK_DEBUG=1`). Subshell-isolated so logging errors never propagate to hook decision flow. `flock`-guarded for concurrent writes; rotation at 1MB via atomic rename.

Skill count: 44 → 46.

---

## 1.1.0 — 2026-04-26

### Added
- `/benchmark-models` — compare AI model outputs side-by-side across OpenAI, Anthropic, Google, Mistral, Groq, Together, Ollama; optionally judge with a separate model; results saved to `~/.vibestack/benchmarks/`
- `/browse` — persistent headless Chromium browser with ~100ms per command; navigate, interact, screenshot, diff, assert element states, test uploads and dialogs, responsive layouts, local HTML rendering, CSS inspector, Puppeteer migration cheatsheet
- `/claude` — independent second opinion from a nested Claude instance; three modes: review (brutally honest diff review), challenge (adversarial failure-mode analysis), consult (read-only Q&A with session continuity)
- `/open-browser` — launch AI-controlled visible Chromium with real-time sidebar activity feed and anti-bot stealth
- `/pair-agent` — pair a remote AI agent (OpenClaw, Hermes, Codex, Cursor) with your browser session via same-machine or ngrok tunnel
- `/setup-browser-cookies` — import cookies from your real Chromium browser into the headless browse session via interactive picker or direct domain import
- `/setup-memory` — install and configure secondbrain persistent memory as a Claude Code MCP tool; supports PGLite local, Supabase existing URL, and Supabase auto-provision paths
- `/pr-summary` — read full diff across all PR commits, categorize changes, write accurate PR body preserving existing author notes
- `/reroll-buddy` — reset the Claude Code `/buddy` companion pet by removing the `companion` key from `~/.claude.json`; preserves all other config
- `/codex` — second-opinion AI reviewer via OpenAI Codex CLI; three modes: review (pass/fail gate on P1 findings), challenge (adversarial edge-case analysis), consult (session continuity)
- `/make-pdf` — generate professional PDFs from markdown, code, or HTML; cover page, TOC, watermarks, custom margins and page sizes, preview mode, per-project defaults
- `/setup-deploy` — detect deploy platform (Fly.io, Render, Vercel, Netlify, Heroku, GitHub Actions, custom), write config to `CLAUDE.md` for `/land-and-deploy`; idempotent
- `CLAUDE.md` — development guide for skill authoring, hook script conventions, and commit discipline
- `ETHOS.md` — five core principles guiding skill design
- `CONTRIBUTING.md` — step-by-step guide for adding and editing skills
- `docs/skills.md` — full skills reference with descriptions, details, and triggers for all skills
- `LICENSE` — MIT license

### Fixed
- `skills/freeze/bin/check-freeze.sh` — `_resolve_path` now resolves symlinks for the boundary itself, not just the incoming file path, so `/freeze` works correctly when the frozen directory is or contains a symlink (e.g. `/tmp` → `/private/tmp` on macOS); also eliminates `//foo` double-slash artifact in deny messages
- `skills/careful/bin/check-careful.sh` — safe exception sed regex uses POSIX `[[:space:]]` instead of `\s` (macOS BSD sed compatibility); anchored with `^` to prevent greedy match failure

### Removed
- `/commit`, `/commit-push`, `/pr-create` — git/PR flow consolidated into `/ship` and `/pr-summary`
- `/code-audit` — overlapped with `/review` and `/cso`
- `/validate` — out of scope; project-level lint/typecheck commands are owned by each repo
- `/docs-sync` — out of scope for vibestack
- `/context-init`, `/context-load` — duplicated by `/context-save` and `/context-restore`
- `/resolve-coderabbit` — review-tool-specific; out of scope

Skill count: 53 → 44.

---

## 1.0.0 — 2026-04-24

### Added
- 30 skills: planning (`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/plan-devex-review`, `/autoplan`, `/plan-tune`), code quality (`/review`, `/ship`, `/investigate`, `/cso`), QA (`/qa`, `/qa-only`, `/canary`, `/land-and-deploy`), design (`/design-consultation`, `/design-review`, `/design-html`, `/design-shotgun`), operations (`/retro`, `/learn`, `/document-release`, `/devex-review`, `/health`, `/benchmark`, `/landing-report`), session (`/context-save`, `/context-restore`), safety (`/careful`, `/freeze`, `/unfreeze`, `/guard`)
- `install` script — symlink-based install, no runtime dependencies beyond Bash
- `uninstall` script — clean removal of symlinks and empty directories
- Hook scripts for `/careful` (destructive command warnings) and `/freeze` (edit scope boundary) with full PreToolUse integration
- State management via `~/.vibestack/` flat files
