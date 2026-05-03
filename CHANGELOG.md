# Changelog

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
