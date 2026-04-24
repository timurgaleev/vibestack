# Skills Reference

Full reference for all tstackvibe skills. For a quick overview, see the README.

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

Registers a PreToolUse hook that intercepts Bash commands matching destructive patterns: `rm -rf`, `DROP TABLE`, `TRUNCATE`, `git push --force`, `git reset --hard`, `git checkout .`, `kubectl delete`, `docker rm -f`. Prompts before executing; safe build artifact deletions (`node_modules`, `.next`, `dist`, etc.) pass through silently.

Active for the session until you end it.

Triggers: `careful mode`, `risky operation`, `be careful`, `extra caution`

---

### `/freeze`
Restrict file edits to a specific directory.

Writes the directory path to `~/.tstackvibe/freeze-dir.txt`. A PreToolUse hook then blocks any Edit or Write targeting a file outside that path. Prevents "fixing" unrelated code while debugging.

Read and Bash operations are unaffected.

Triggers: `freeze edits to directory`, `lock editing scope`, `restrict file changes`, `only edit this folder`

---

### `/unfreeze`
Clear the freeze boundary.

Removes `~/.tstackvibe/freeze-dir.txt`. Edits are allowed everywhere again. The hook remains registered for the session but allows all paths since no state file exists.

Triggers: `unfreeze edits`, `unlock all directories`, `remove edit restrictions`, `allow all edits`

---

### `/guard`
Full safety mode: `/careful` + `/freeze` combined.

Activates destructive command warnings and edit-scope restriction in one command. Use when touching production systems or debugging live issues.

To remove the edit boundary: `/unfreeze`. To deactivate everything: end the session.

Triggers: `full safety mode`, `guard against mistakes`, `maximum safety`, `guard mode`, `lock it down`
