# Changelog

## Unreleased

### Added
- `/tdd` — test-driven development with vertical-slice red-green-refactor loop. Tests verify behavior through public interfaces (so they survive refactors); anti-pattern callout for horizontal slicing; per-cycle checklist. Sub-docs: `deep-modules.md`, `interface-design.md`, `mocking.md`, `refactoring.md`, `tests.md`.
- `/improve-arch` — find deepening opportunities in an existing codebase: turn shallow modules into deep ones (small interface, deep implementation) for testability and AI-navigability. Precise glossary (module, interface, depth, seam, adapter, leverage, locality); deletion test; explore → present candidates → grilling loop. Optional `CONTEXT.md` and `docs/adr/` integration. Sub-docs: `DEEPENING.md`, `INTERFACE-DESIGN.md`, `LANGUAGE.md`.

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
