# Changelog

## Unreleased

---

## 1.1.0 — 2026-04-26

### Added
- `/benchmark-models` — compare AI model outputs side-by-side across OpenAI, Anthropic, Google, Mistral, Groq, Together, Ollama; optionally judge with a separate model; results saved to `~/.tstackvibe/benchmarks/`
- `/browse` — persistent headless Chromium browser with ~100ms per command; navigate, interact, screenshot, diff, assert element states, test uploads and dialogs, responsive layouts, local HTML rendering, CSS inspector, Puppeteer migration cheatsheet
- `/claude` — independent second opinion from a nested Claude instance; three modes: review (brutally honest diff review), challenge (adversarial failure-mode analysis), consult (read-only Q&A with session continuity)
- `/open-browser` — launch AI-controlled visible Chromium with real-time sidebar activity feed and anti-bot stealth
- `/pair-agent` — pair a remote AI agent (OpenClaw, Hermes, Codex, Cursor) with your browser session via same-machine or ngrok tunnel
- `/setup-browser-cookies` — import cookies from your real Chromium browser into the headless browse session via interactive picker or direct domain import
- `/setup-memory` — install and configure secondbrain persistent memory as a Claude Code MCP tool; supports PGLite local, Supabase existing URL, and Supabase auto-provision paths
- `/code-audit` — deep codebase audit for architecture, quality, security, performance, and maintainability; prioritized issue list with severity ratings; audit only, no code changes
- `/validate` — run lint, typecheck, and tests; detect cascading failures with shared root causes; fix all automatically; repeat until clean
- `/commit` — create a git commit with conventional `<type>: <subject>` format; refuses to commit secrets or generated files
- `/commit-push` — same as `/commit` but also pushes to remote after confirming push target
- `/pr-create` — run validation, analyze full diff, create PR with summary, per-file breakdown, and test plan
- `/pr-summary` — read full diff across all PR commits, categorize changes, write accurate PR body preserving existing author notes
- `/resolve-coderabbit` — fetch CodeRabbit inline comments, evaluate each technically (ACCEPT / SKIP / REJECT), apply fixes in severity order, resolve GitHub review threads
- `/docs-sync` — analyze code and existing documentation, identify missing/stale/inaccurate docs, update README, API docs, inline comments, and guides
- `/reroll-buddy` — reset the Claude Code `/buddy` companion pet by removing the `companion` key from `~/.claude.json`; preserves all other config
- `/context-init` — read project docs and key source files, write a structured context snapshot to `./context.md` for use by `/context-load`
- `/context-load` — read `./context.md` and restore working state; faster than re-reading all docs from scratch
- `/codex` — second-opinion AI reviewer via OpenAI Codex CLI; three modes: review (pass/fail gate on P1 findings), challenge (adversarial edge-case analysis), consult (session continuity)
- `/make-pdf` — generate professional PDFs from markdown, code, or HTML; cover page, TOC, watermarks, custom margins and page sizes, preview mode, per-project defaults
- `/setup-deploy` — detect deploy platform (Fly.io, Render, Vercel, Netlify, Heroku, GitHub Actions, custom), write config to `CLAUDE.md` for `/land-and-deploy`; idempotent
- `CLAUDE.md` — development guide for skill authoring, hook script conventions, and commit discipline
- `ETHOS.md` — five core principles guiding skill design
- `CONTRIBUTING.md` — step-by-step guide for adding and editing skills
- `docs/skills.md` — full skills reference with descriptions, details, and triggers for all 53 skills
- `LICENSE` — MIT license

### Fixed
- `skills/careful/bin/check-careful.sh` — safe exception sed regex uses POSIX `[[:space:]]` instead of `\s` (macOS BSD sed compatibility); anchored with `^` to prevent greedy match failure

---

## 1.0.0 — 2026-04-24

### Added
- 30 skills: planning (`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/plan-devex-review`, `/autoplan`, `/plan-tune`), code quality (`/review`, `/ship`, `/investigate`, `/cso`), QA (`/qa`, `/qa-only`, `/canary`, `/land-and-deploy`), design (`/design-consultation`, `/design-review`, `/design-html`, `/design-shotgun`), operations (`/retro`, `/learn`, `/document-release`, `/devex-review`, `/health`, `/benchmark`, `/landing-report`), session (`/context-save`, `/context-restore`), safety (`/careful`, `/freeze`, `/unfreeze`, `/guard`)
- `install` script — symlink-based install, no runtime dependencies beyond Bash
- `uninstall` script — clean removal of symlinks and empty directories
- Hook scripts for `/careful` (destructive command warnings) and `/freeze` (edit scope boundary) with full PreToolUse integration
- State management via `~/.tstackvibe/` flat files
