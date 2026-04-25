# Changelog

## Unreleased

### Added
- `/codex` — second-opinion AI reviewer via OpenAI Codex CLI; three modes: review (pass/fail gate), challenge (adversarial), consult (session continuity)
- `/make-pdf` — generate professional PDFs from markdown, code, or HTML; supports cover page, TOC, watermarks, custom margins and page sizes
- `/setup-deploy` — configure deployment settings (platform, production URL, health check) written to CLAUDE.md for use by `/land-and-deploy`
- `CLAUDE.md` — development guide for skill authoring and hook script conventions
- `ETHOS.md` — five core principles guiding skill design
- `CONTRIBUTING.md` — step-by-step guide for adding and editing skills
- `docs/skills.md` — full skills reference with descriptions, details, and triggers
- `LICENSE` — MIT license

### Fixed
- `skills/careful/bin/check-careful.sh` — safe exception sed regex now uses POSIX `[[:space:]]` instead of `\s` (macOS BSD sed does not support `\s`); anchored with `^` to prevent greedy match failure. `rm -rf node_modules` and other build artifact deletions now pass through silently as intended.

---

## 1.0.0 — 2026-04-24

### Added
- 30 skills: planning (`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/plan-devex-review`, `/autoplan`, `/plan-tune`), code quality (`/review`, `/ship`, `/investigate`, `/cso`), QA (`/qa`, `/qa-only`, `/canary`, `/land-and-deploy`), design (`/design-consultation`, `/design-review`, `/design-html`, `/design-shotgun`), operations (`/retro`, `/learn`, `/document-release`, `/devex-review`, `/health`, `/benchmark`, `/landing-report`), session (`/context-save`, `/context-restore`), safety (`/careful`, `/freeze`, `/unfreeze`, `/guard`)
- `install` script — symlink-based install, no runtime dependencies beyond Bash
- `uninstall` script — clean removal of symlinks and empty directories
- Hook scripts for `/careful` (destructive command warnings) and `/freeze` (edit scope boundary) with full PreToolUse integration
- State management via `~/.tstackvibe/` flat files
