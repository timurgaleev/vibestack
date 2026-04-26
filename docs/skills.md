# Skills Reference

Full reference for all vibestack skills. For a quick overview, see the README.

---

## Product & Planning

### `/office-hours`
Structured idea development through forcing questions.

Two modes:
- **Startup** — six forcing questions that stress-test demand, pain, urgency, and competitive moat. Synthesizes answers into a one-page brief with recommended next step.
- **Builder** — design thinking flow for exploring ideas freely without startup constraints.

Triggers: `startup mode`, `builder mode`, `office hours`

---

### `/plan-ceo-review`
Challenge a plan's scope and ambition from a product/business perspective.

Four modes: **expand** (too cautious?), **selective** (right scope?), **hold** (not ready?), **reduce** (too much?). Surfaces where the plan undersells, over-promises, or ignores real constraints. Ends with a single recommended next action.

Triggers: `ceo review`, `product review`, `challenge this plan`

---

### `/plan-eng-review`
Engineering review of a technical plan.

Covers: architecture decisions, data model, API contracts, scalability assumptions, operational concerns, and risk assessment. Flags blockers and recommends the next engineering action.

Triggers: `eng review`, `engineering review`, `review the technical plan`

---

### `/plan-design-review`
UX review of a design plan before implementation.

Covers: user flows, information architecture, interaction patterns, edge cases, accessibility, and consistency with existing patterns. Surfaces gaps between what's designed and what users will experience.

Triggers: `design review`, `ux review`, `review the design plan`

---

### `/plan-devex-review`
Developer experience review — APIs, CLIs, SDKs.

Three modes: **expand** (add features), **polish** (improve ergonomics), **triage** (cut to essentials). Reviews naming, discoverability, error messages, documentation, and onboarding friction.

Triggers: `devex review`, `api review`, `review developer experience`

---

### `/autoplan`
Run all four plan reviews (CEO, eng, design, devex) automatically.

Auto-decides which mode applies for each review based on the plan content. Surfaces only the calls that require a human judgment. Useful when you want a full review pass without choosing modes manually.

Triggers: `autoplan`, `run all reviews`, `full plan review`

---

### `/plan-tune`
Adjust skill behavior — reduce confirmations, set defaults, enable terse mode.

Tells Claude how to handle repetitive confirmation prompts in the planning skills: skip them, remember a default, or use one-line responses. Useful when running many reviews in sequence.

Triggers: `tune plan`, `reduce confirmations`, `terse mode`

---

## Code Quality & Shipping

### `/review`
Pre-landing PR code review.

Checks: correctness, security vulnerabilities, database safety (migrations, N+1s), test coverage, edge cases. Outputs a structured report with MUST-FIX and SHOULD-FIX items. Does not merge — review only.

Triggers: `review this PR`, `code review`, `pre-landing review`

---

### `/ship`
Full ship workflow from working branch to merged PR.

Steps: establish merge base, run tests, code review, version bump if needed, create PR. Stops at each gate — does not proceed on failure. The ship command is a checklist, not a one-click deploy.

Triggers: `ship this`, `ship it`, `ready to ship`

---

### `/investigate`
Systematic debugging with root cause analysis.

Iron Law: **never implement a fix until the root cause is confirmed.** Four phases: investigate (collect raw data), analyze (read the full call chain), hypothesize (rank hypotheses, ask why 5 times), implement (fix root cause, add regression test).

If `/freeze` is active, edits are restricted to the frozen directory during investigation.

Triggers: `debug this`, `fix this bug`, `why is this broken`, `root cause analysis`, `investigate this error`

---

### `/cso`
Security audit — OWASP Top 10 + STRIDE threat model.

Covers: injection, authentication, authorization, cryptography, data exposure, configuration, dependencies. Outputs findings ranked by severity with recommended remediations.

Triggers: `security audit`, `cso`, `threat model`

---

### `/code-audit`
Deep code audit — analyze entire codebase for issues, root causes, and improvements.

Systematic pass through architecture, code quality, security, performance, and maintainability. Produces a prioritized issue list with severity ratings and recommended fixes. Does not change code — audit only.

Triggers: `code audit`, `audit the codebase`, `deep code review`

---

### `/validate`
Run lint, typecheck, and tests. Fix all failures automatically.

Detects project type (Node.js, Python, Go, Rust), runs all quality checks in sequence, identifies cascading failures with shared root causes, and fixes them. Repeats until all checks pass. Reports what was fixed.

Triggers: `validate`, `run checks`, `lint and test`

---

### `/commit`
Create a git commit with conventional format.

Analyzes staged and unstaged changes, drafts a commit message in `<type>: <subject>` format, stages relevant files, and creates the commit. Refuses to commit secrets or generated files.

Triggers: `commit`, `commit these changes`, `git commit`

---

### `/commit-push`
Create a git commit and push to remote.

Same as `/commit` but also pushes to the remote branch after committing. Confirms the push target before proceeding.

Triggers: `commit and push`, `commit push`, `push this`

---

### `/pr-create`
Create a pull request with proper format.

Runs validation first, gathers the full diff, analyzes every changed file for purpose and impact, then creates a PR with summary, changes, and test plan. Uses `<type>(<scope>): <subject>` title format.

Triggers: `create pr`, `open pr`, `pull request`

---

### `/pr-summary`
Analyze all PR changes and update the PR description with an accurate summary.

Reads the full diff across all commits in the PR (not just the latest), categorizes changes, and writes an accurate PR body with summary, changes, and test plan. Preserves existing author notes.

Triggers: `update pr description`, `pr summary`, `summarize pr`

---

### `/resolve-coderabbit`
Address CodeRabbit review comments on a PR.

Fetches all CodeRabbit inline comments, evaluates each technically against the codebase (ACCEPT / SKIP / REJECT), applies fixes in severity order, and resolves GitHub review threads. Does not blindly accept suggestions — rejects YAGNI, scope creep, and architecture conflicts.

Triggers: `resolve coderabbit`, `fix coderabbit comments`, `address review comments`

---

## QA & Testing

### `/qa`
Iterative test-fix-verify loop for a feature.

Tests the feature, finds bugs, fixes them, verifies the fix, and repeats until passing. Produces a test report with what was found, fixed, and verified. Use when you want QA with fixes, not just a report.

Triggers: `qa this`, `test and fix`, `qa the feature`

---

### `/qa-only`
QA audit — finds bugs, does not fix them.

Same coverage as `/qa` but stops after reporting. Useful for a clean separation between QA and engineering, or when you want to decide which bugs to fix before touching code.

Triggers: `qa report`, `qa only`, `find bugs`

---

### `/canary`
Canary deploy health check.

Compares error rates and latency between canary and stable. Checks logs for new error patterns. Outputs a go/no-go recommendation with evidence. Use after a partial rollout to decide whether to proceed or roll back.

Triggers: `canary check`, `check canary`, `canary health`

---

### `/land-and-deploy`
Merge a PR, monitor CI, verify production health after deploy.

Merges on green CI, watches the deploy, queries error rates and latency, and surfaces any post-deploy regressions. Ends with a production health verdict.

Triggers: `land and deploy`, `merge and deploy`, `deploy this PR`

---

## Design

### `/design-consultation`
Structured design direction conversation before building UI.

Asks targeted questions about purpose, users, tone, constraints, and existing patterns. Synthesizes answers into a design brief you review before any implementation starts. Prevents building the wrong thing.

Triggers: `design consultation`, `before I build the UI`, `design direction`

---

### `/design-review`
Review implemented UI for visual quality.

Checks: hierarchy, typography, spacing, color, consistency, interaction affordances, and AI slop (Lorem ipsum, placeholder assets, generic layouts). Outputs a prioritized list of improvements.

Triggers: `design review`, `review the UI`, `visual review`

---

### `/design-html`
Generate a realistic single-file HTML mockup.

No Lorem ipsum. No placeholder content. Real copy, real data shapes, real interaction states. Outputs a self-contained HTML file you can open in a browser immediately.

Triggers: `design html`, `html mockup`, `build a mockup`

---

### `/design-shotgun`
Generate three distinct design variants side-by-side.

Produces three meaningfully different approaches (not color swaps) for the same feature. Useful for early-stage direction-finding when you're not sure which design pattern fits.

Triggers: `design shotgun`, `three designs`, `design variants`

---

## Operations

### `/retro`
Weekly engineering retrospective.

Four sections: shipped (what landed), broke (incidents, regressions), blocked (what slowed the team), action items (concrete changes for next week). Pulls from git history and recent CI. Takes ~5 minutes.

Triggers: `retro`, `weekly retro`, `retrospective`

---

### `/learn`
Capture and persist project learnings.

Writes structured learnings to a project learnings file to prevent solving the same problem twice. Covers: what was the problem, what was tried, what worked, what to do next time.

Triggers: `learn`, `save learning`, `capture this`

---

### `/document-release`
Write release notes and update CHANGELOG.

Reads git log since last tag, groups changes by type (feat/fix/perf/breaking), writes human-readable release notes, and updates CHANGELOG.md. Outputs a draft you review before committing.

Triggers: `document release`, `write release notes`, `update changelog`

---

### `/devex-review`
Developer experience review of the project setup.

Checks: first-run setup (clone → running in how many steps?), CI speed and reliability, tooling consistency, documentation accuracy, onboarding friction. Outputs a DX score with specific improvement recommendations.

Triggers: `devex review`, `dx review`, `review developer experience`

---

### `/health`
Code quality dashboard.

Reports: type errors, lint warnings, test count and pass rate, coverage percentage, known security advisories, and a composite health score. Use as a quick project health snapshot.

Triggers: `health check`, `project health`, `code quality dashboard`

---

### `/benchmark`
Performance benchmarking.

Measures: build time, test suite duration, bundle sizes. Compares against a baseline (last commit or specified ref). Flags regressions. Use before and after performance-sensitive changes.

Triggers: `benchmark`, `performance check`, `measure performance`

---

### `/landing-report`
PR queue dashboard.

Lists: PRs with CI status, which are merge-ready, which are blocked, and recent merges. Gives a snapshot of what's in flight without opening GitHub.

Triggers: `landing report`, `pr queue`, `what's ready to merge`

---

### `/docs-sync`
Analyze code and documentation, find gaps, update docs.

Reads source files and existing documentation, identifies where docs are missing, stale, or inaccurate, and updates them. Covers README, API docs, inline comments, and guides. Does not invent content — only documents what the code actually does.

Triggers: `docs sync`, `update documentation`, `sync docs`

---

### `/reroll-buddy`
Reset the Claude Code `/buddy` companion pet so a new one can be picked.

Removes the `companion` key from `~/.claude.json` after user confirmation. After reset, run `/buddy` to pick a new pet. Modifies only the companion key — all other Claude Code config is preserved.

Triggers: `reroll buddy`, `reset pet`, `reset companion`, `new buddy`

---

## Session & Context

### `/context-save`
Save working context to resume later.

Captures: current branch, uncommitted changes summary, decisions made, work remaining, open questions. Writes to a context file you can restore in a future session.

Triggers: `save context`, `context save`, `save my place`

---

### `/context-restore`
Restore saved context and pick up where you left off.

Reads the context file, summarizes the state, and picks up the active task. Use at the start of a session after `/context-save`.

Triggers: `restore context`, `context restore`, `pick up where I left off`

---

### `/context-init`
Initialize project context by reading docs and saving to `./context.md`.

Reads the project's README, CLAUDE.md, docs, and key source files to build a structured context snapshot. Writes it to `./context.md` for use by `/context-load` in future sessions. Run once when starting a new project.

Triggers: `init context`, `initialize context`, `context init`

---

### `/context-load`
Load saved project context from `./context.md`.

Reads the previously saved context snapshot and restores working state. Shorter than re-reading all docs from scratch. Use at the start of a session when `/context.md` already exists.

Triggers: `load context`, `context load`, `restore saved context`

---

## Safety & Scope Control

### `/careful`
Activate extra caution for risky operations.

Registers a PreToolUse hook that intercepts Bash commands matching destructive patterns: `rm -rf`, `DROP TABLE`, `TRUNCATE`, `git push --force`, `git reset --hard`, `git checkout .`, `kubectl delete`, `docker rm -f`. Prompts before executing; safe build artifact deletions (`node_modules`, `.next`, `dist`, etc.) pass through silently.

Active for the session until you end it.

Triggers: `careful mode`, `risky operation`, `be careful`, `extra caution`

---

### `/freeze`
Restrict file edits to a specific directory.

Writes the directory path to `~/.vibestack/freeze-dir.txt`. A PreToolUse hook then blocks any Edit or Write targeting a file outside that path. Prevents "fixing" unrelated code while debugging.

Read and Bash operations are unaffected.

Triggers: `freeze edits to directory`, `lock editing scope`, `restrict file changes`, `only edit this folder`

---

### `/unfreeze`
Clear the freeze boundary.

Removes `~/.vibestack/freeze-dir.txt`. Edits are allowed everywhere again. The hook remains registered for the session but allows all paths since no state file exists.

Triggers: `unfreeze edits`, `unlock all directories`, `remove edit restrictions`, `allow all edits`

---

### `/guard`
Full safety mode: `/careful` + `/freeze` combined.

Activates destructive command warnings and edit-scope restriction in one command. Use when touching production systems or debugging live issues.

To remove the edit boundary: `/unfreeze`. To deactivate everything: end the session.

Triggers: `full safety mode`, `guard against mistakes`, `maximum safety`, `guard mode`, `lock it down`

---

## Tooling & Integrations

### `/codex`
Second-opinion code reviewer via OpenAI Codex CLI.

Three modes:
- **Review** — runs `codex review` against the current branch diff, applies a pass/fail gate on `[P1]` critical findings. Includes cross-model comparison if `/review` was already run in the session.
- **Challenge** — adversarial mode: Codex tries to find edge cases, race conditions, security holes, and failure modes that a normal review would miss.
- **Consult** — ask Codex anything about the codebase. Supports session continuity so follow-up questions preserve context.

Requires `codex` CLI (`npm install -g @openai/codex`) and an OpenAI API key.

Triggers: `codex review`, `second opinion`, `outside voice challenge`

---

### `/make-pdf`
Generate professional PDFs from markdown, code, or HTML.

Supports cover pages, tables of contents, watermarks, custom margins, and page sizes. Includes a preview mode to open a temporary PDF in the system viewer, and a setup mode to configure per-project defaults.

Requires the `make-pdf` binary at `~/.claude/skills/vibestack/make-pdf/dist/pdf`, or override via `$MAKE_PDF_BIN`.

Triggers: `make pdf`, `generate pdf`, `create pdf`, `export pdf`, `pdf preview`

---

### `/setup-deploy`
Configure deployment settings for `/land-and-deploy`.

Detects your deploy platform (Fly.io, Render, Vercel, Netlify, Heroku, GitHub Actions, custom), production URL, health check endpoints, and deploy status commands. Writes everything to the `## Deploy Configuration` section of `CLAUDE.md` so future deploys are automatic. Idempotent — safe to re-run if your setup changes.

Triggers: `configure deploy`, `setup deployment`, `set deploy platform`

---

### `/benchmark-models`
Compare AI model outputs side-by-side to find the best fit for a task.

Run a prompt against multiple providers (OpenAI, Anthropic, Google, Mistral, Groq, Together, local Ollama), optionally judge results with a separate model. Saves results to `~/.vibestack/benchmarks/` for later comparison. Uses the `vibe-model-benchmark` binary from `~/.vibestack/bin/`.

Triggers: `benchmark models`, `compare models`, `test models`

---

### `/browse`
Fast headless browser for QA testing and site dogfooding.

Navigate any URL, interact with elements, verify page state, diff before/after actions, take annotated screenshots, check responsive layouts, test forms and uploads, handle dialogs, and assert element states. ~100ms per command. Requires the browse binary at `~/.claude/skills/vibestack/browse/dist/browse`. Build via `cd ~/.claude/skills/vibestack && ./setup`.

Triggers: `browse a page`, `headless browser`, `take page screenshot`

---

### `/claude`
Get an independent second opinion from a nested Claude instance.

Three modes: **Review** (brutally honest diff review via `claude -p`), **Challenge** (adversarial failure-mode analysis), **Consult** (read-only Q&A about the repo). All modes run nested Claude with `--disable-slash-commands`; review/challenge are tool-less, consult uses Read/Grep/Glob only. Session IDs saved for consult continuity.

Triggers: `claude review`, `claude challenge`, `ask claude`

---

### `/open-browser`
Launch vibestack Browser — AI-controlled Chromium with sidebar extension.

Opens a visible browser window where every action is visible in real time. The sidebar shows a live activity feed and chat. Anti-bot stealth built in. Guides user through Side Panel setup and runs a live demo. Requires the browse binary at `~/.claude/skills/vibestack/browse/dist/browse`. Build via `cd ~/.claude/skills/vibestack && ./setup`.

Triggers: `open browser`, `launch chromium`, `show me the browser`

---

### `/pair-agent`
Pair a remote AI agent with your browser session.

Generates a one-time setup key and instructions another agent can use to connect. Works with OpenClaw, Hermes, Codex, Cursor, or any agent that can make HTTP requests. Each paired agent gets its own tab with scoped access. Supports same-machine (direct credential write) and remote (ngrok tunnel) modes.

Triggers: `pair with agent`, `connect remote agent`, `share my browser`

---

### `/setup-browser-cookies`
Import cookies from your real Chromium browser into the headless browse session.

Opens an interactive picker UI where you select which cookie domains to import. Use before QA testing authenticated pages. Supports direct domain import without the UI. Checks CDP mode first — skips import if already connected to real browser.

Triggers: `import browser cookies`, `login to test site`, `setup authenticated session`

---

### `/setup-memory`
Set up secondbrain persistent memory for this coding agent.

Install the secondbrain CLI, initialize a local PGLite or Supabase brain, register as a Claude Code MCP tool, and capture per-remote trust policy. Three paths: PGLite local (zero accounts), Supabase existing URL, or Supabase auto-provision. Shortcut modes: `--repo` (policy only), `--switch` (engine migration), `--resume-provision`, `--cleanup-orphans`.

Triggers: `setup memory`, `setup secondbrain`, `install secondbrain`, `connect secondbrain`
