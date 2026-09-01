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

Reviews which questions the skills actually asked you — from a local question log — with counts and how often you took the recommendation. Set a per-question policy (never-ask, always-ask, ask-only-for-one-way), and inspect the dual-track profile: what you declared about your preferences versus what your choices suggest. A one-way door (anything destructive or irreversible) is always asked, whatever the policy says.

Triggers: `tune plan`, `reduce confirmations`, `terse mode`

---

## Code Quality & Shipping

### `/review`
Pre-landing PR code review.

Checks: correctness, security vulnerabilities, database safety (migrations, N+1s), test coverage, edge cases. Outputs a structured report with MUST-FIX and SHOULD-FIX items. Does not merge — review only.

Triggers: `review this PR`, `code review`, `pre-landing review`

---

### `/spec`
Turn vague intent into a precise, executable spec in five phases.

Phases: understand the why (+ optional dedupe), scope and boundaries, technical interrogation (mandatory code-reading first), draft review, file. Optional codex quality gate (0-10, fail-closed secret redaction before dispatch). Archives the spec under `~/.vibestack/projects/<slug>/specs/`. Plan-mode-aware: files the issue and loads it into the active plan file in plan mode; files + spawns `claude -p` in a fresh worktree in execution mode. `/ship` can close the source issue on merge.

Triggers: `spec this out`, `file an issue`, `write up a ticket`, `turn this into a backlog item`

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

### `/pr-summary`
Analyze all PR changes and update the PR description with an accurate summary.

Reads the full diff across all commits in the PR (not just the latest), categorizes changes, and writes an accurate PR body with summary, changes, and test plan. Preserves existing author notes.

Triggers: `update pr description`, `pr summary`, `summarize pr`

---

### `/tdd`
Test-driven development with the red-green-refactor loop, vertical-slice tracer bullets.

Tests verify behavior through public interfaces, not implementation details — so they survive refactors. Anti-pattern: horizontal slicing (write all tests then all code). Workflow: plan behaviors → tracer bullet test → incremental RED→GREEN cycles → refactor only when GREEN. Sub-docs: `deep-modules.md`, `interface-design.md`, `mocking.md`, `refactoring.md`, `tests.md`.

Triggers: `tdd`, `red-green-refactor`, `test-first development`, `build with tdd`, `test-driven`

---

### `/improve-arch`
Find deepening opportunities in an existing codebase — refactor shallow modules into deep ones (small interface, deep implementation) for testability and AI-navigability.

Glossary-first approach: uses precise terms (module, interface, depth, seam, adapter, leverage, locality) and avoids drifting into "component/service/boundary." Three phases: explore (deletion test, friction notes), present numbered candidates, grilling loop on the chosen candidate. Optional integration with project `CONTEXT.md` domain glossary and `docs/adr/`. Sub-docs: `DEEPENING.md`, `INTERFACE-DESIGN.md`, `LANGUAGE.md`.

Triggers: `improve architecture`, `find refactoring opportunities`, `deepen modules`, `architecture review`, `make this more testable`

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

Writes structured learnings to a project learnings file to prevent solving the same problem twice. Covers: what was the problem, what was tried, what worked, what to do next time. Plain `/learn` runs the full loop — show recorded learnings, capture new ones from the current session, then sync consent-gated copies into connected memory (memex). `/learn sync` runs the sync step alone.

Triggers: `learn`, `save learning`, `capture this`

---

### `/document-release`
Post-ship documentation sweep.

Builds a Diataxis coverage map of what shipped vs what's documented (reference / how-to / tutorial / explanation), detects architecture-diagram drift, polishes the CHANGELOG entry against a 0-3 sell-test rubric, syncs the PR title to `v<VERSION>`, and surfaces "Documentation Debt" in the PR body when gaps are found. Auto-updates factual content; asks for narrative changes.

Triggers: `update docs after ship`, `document what changed`, `post-ship docs`

---

### `/document-generate`
Generate complete documentation from scratch.

Uses the Diataxis framework to produce structured documentation for a feature, module, or entire project: tutorials (learning-oriented), how-tos (task-oriented), reference (information-oriented), and explanation (understanding-oriented). Researches the full codebase surface first, then writes — accuracy over elegance. Can be invoked standalone or by `/document-release` to fill coverage gaps.

Triggers: `write docs for this`, `generate documentation`, `document this feature`, `create a tutorial`, `write a how-to`, `explain this module`

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

## Safety & Scope Control

### `/careful`
Activate extra caution for risky operations.

Registers a PreToolUse hook that intercepts Bash commands matching destructive patterns: `rm -rf`, `DROP TABLE`, `TRUNCATE`, `git push --force`, `git reset --hard`, `git checkout .`, `kubectl delete`, `docker rm -f`. Most matches prompt and are overridable. A small catastrophic set is blocked outright and cannot be overridden while the skill is active: recursive deletion of `/` or your home directory, and a force-push to the repo's default branch. Only simple commands qualify for that tier — anything with `;`, `&&`, a pipe or a newline falls back to a prompt, and `--force-with-lease` never hard-denies. Safe build artifact deletions (`node_modules`, `.next`, `dist`, etc.) pass through silently.

Active for the session until you end it.

**Your own patterns.** Add one POSIX ERE per line to
`~/.vibestack/careful-patterns.txt` (or, for one project only,
`~/.vibestack/projects/<slug>/careful-patterns.txt`); blank lines and `#`
comments are ignored. A match warns, naming the pattern that fired.

These are **additive only** — they are consulted after every built-in family, so
a file can add a warning but can never silence one. A guard a project can turn
off is not a guard. A pattern that will not compile is skipped rather than
taking the hook down with it, so a typo costs you that one rule, not the guard.

```
# ~/.vibestack/careful-patterns.txt
terraform[[:space:]]+destroy
flyctl[[:space:]]+apps[[:space:]]+destroy
```

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

Activates the destructive-command guard (warnings, plus the non-overridable tier described under `/careful`) and edit-scope restriction in one command. Use when touching production systems or debugging live issues.

To remove the edit boundary: `/unfreeze`. To deactivate everything: end the session.

Triggers: `full safety mode`, `guard against mistakes`, `maximum safety`, `guard mode`, `lock it down`

---

## Tooling & Integrations

### `/vibe`
Router for the suite — name the task, get pointed at the right skill. Mostly for Codex and other hosts with no slash-command picker, where a skill is referenced as `$vibe` inside an ordinary message; `agents/openai.yaml` names it as the pack's entry point. Routes on intent rather than listing every skill, and hands off to this file for the full index.

Triggers: `which vibestack skill`, `list vibestack skills`, `vibe help`

---

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

Requires the `make-pdf` binary at `<vibestack checkout>/make-pdf/dist/pdf`, or override via `$MAKE_PDF_BIN`.

Triggers: `make pdf`, `generate pdf`, `create pdf`, `export pdf`, `pdf preview`

---

### `/setup-deploy`
Configure deployment settings for `/land-and-deploy`.

Detects your deploy platform (Fly.io, Render, Vercel, Netlify, Heroku, GitHub Actions, custom), production URL, health check endpoints, and deploy status commands. Writes everything to the `## Deploy Configuration` section of `CLAUDE.md` so future deploys are automatic. Idempotent — safe to re-run if your setup changes.

Triggers: `configure deploy`, `setup deployment`, `set deploy platform`

---

### `/benchmark-models`
Compare AI model outputs side-by-side to find the best fit for a task.

Run a prompt against multiple providers (OpenAI, Anthropic, Google, Mistral, Groq, Together, local Ollama), optionally judge results with a separate model. Saves results to `~/.vibestack/benchmarks/` for later comparison. Uses the `vibe-model-benchmark` binary from `~/.vibestack/bin/` — vibestack does not bundle this binary; see [`external-tools.md`](external-tools.md#vibe-model-benchmark).

Triggers: `benchmark models`, `compare models`, `test models`

---

### `/browse`
Fast headless browser for QA testing and site dogfooding.

Navigate any URL, interact with elements, verify page state, diff before/after actions, take annotated screenshots, check responsive layouts, test forms and uploads, handle dialogs, and assert element states. ~100ms per command. Requires a browse daemon binary at `${CLAUDE_SKILL_DIR}/../browse/bin/vibe-browse` — vibestack does not bundle the browse daemon; see [`external-tools.md`](external-tools.md#browse-daemon).

Triggers: `browse a page`, `headless browser`, `take page screenshot`

---

### `/claude`
Get an independent second opinion from a nested Claude instance.

Three modes: **Review** (brutally honest diff review via `claude -p`), **Challenge** (adversarial failure-mode analysis), **Consult** (read-only Q&A about the repo). All modes run nested Claude with `--disable-slash-commands`; review/challenge are tool-less, consult uses Read/Grep/Glob only. Session IDs saved for consult continuity.

Triggers: `claude review`, `claude challenge`, `ask claude`

---

### `/open-browser`
Launch vibestack Browser — AI-controlled Chromium with sidebar extension.

Opens a visible browser window where every action is visible in real time. The sidebar shows a live activity feed and chat. Anti-bot stealth built in. Guides user through Side Panel setup and runs a live demo. Requires a browse daemon binary at `${CLAUDE_SKILL_DIR}/../browse/bin/vibe-browse` — vibestack does not bundle the browse daemon; see [`external-tools.md`](external-tools.md#browse-daemon).

Triggers: `open browser`, `launch chromium`, `show me the browser`

---

### `/pair-agent`
Pair a remote AI agent with your browser session.

Generates a one-time setup key and instructions another agent can use to connect. Works with OpenClaw, Hermes, Codex, Cursor, or any agent that can make HTTP requests. Each paired agent gets its own tab. Default access is read + write + admin + meta — a paired agent can execute JavaScript and read cookies and storage; `--control` additionally allows stop/restart/disconnect, and `--restrict` is what narrows access. Supports same-machine (direct credential write) and remote (ngrok tunnel) modes.

Remote mode asks for consent once per machine before opening a tunnel — it exposes a browser that is already logged into your accounts, so the answer is recorded in `vibe-config` under `pair_agent` and stands until you set it back to `off`. Your ngrok authtoken never passes through the chat: you run `ngrok config add-authtoken` in your own terminal and the skill only verifies the result.

To revoke one agent, the daemon serves a root-only `DELETE /token/<clientId>`; there is no CLI wrapper for it yet, and `$B tunnel revoke` does not exist. To revoke everything at once, stop the browse daemon (`$B stop`) — scoped tokens live in daemon memory, so every issued token and pending setup key dies with it.

Triggers: `pair with agent`, `connect remote agent`, `share my browser`

---

### `/setup-browser-cookies`
Import cookies from your real Chromium browser into the headless browse session.

Opens an interactive picker UI where you select which cookie domains to import. Use before QA testing authenticated pages. Supports direct domain import without the UI. Checks CDP mode first — skips import if already connected to real browser.

Triggers: `import browser cookies`, `login to test site`, `setup authenticated session`

---

## Web & Tooling (added v1.17.x)

### `/scrape`
Pull structured data from a web page with the browse shim — navigate, extract by selector, return JSON. Read-only.

Triggers: `scrape this page`, `get data from`, `pull from`, `extract from`

---

### `/skillify`
Turn a working browse/scrape flow into a reusable skill — write a new `SKILL.md` from the captured steps, render-validate, brand-check, and install.

Triggers: `skillify this`, `make this a skill`, `save this flow as a skill`

---

### `/diagram`
Render a Mermaid diagram offline — the renderer is vendored in the repo, so nothing is fetched at render time or afterwards. Emits four artifacts: `.mmd` (the source to edit), `.svg` (vector), `.html` (the SVG inlined, opens anywhere), and `.png` (for chat and READMEs).

Triggers: `draw a diagram`, `make a mermaid diagram`, `render this flowchart`

---

### `/connect-chrome`
Reuse your real Chrome's logged-in cookies in the browse daemon (via CDP import on `--remote-debugging-port`), so authenticated pages work without re-logging-in.

Triggers: `connect to chrome`, `use my chrome session`, `import chrome cookies`

---

### `/vibe-upgrade`
Update the installed vibestack pack to the latest release — pull the repo (ff-only, never forces), re-run install, and summarize the CHANGELOG delta.

Triggers: `upgrade vibestack`, `update vibestack`, `pull latest skills`
