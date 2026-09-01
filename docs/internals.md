# vibestack internals

How the pack works under the skills: the binaries, the shared snippets, the
preamble flags, and the memory architecture. For the skill catalogue see
[`skills.md`](skills.md); for the spec-compatibility matrix see
[`agent-skills-compatibility-audit.md`](agent-skills-compatibility-audit.md).

## Architecture: brain vs. local state

vibestack splits durable knowledge in two:

- **memex is the brain** — a hosted Postgres + pgvector MCP server. It is the
  **semantic-recall** layer: skills query it for product/goal/prior context
  (`mcp__memex__search`, `entity_recall`, …). It indexes its own corpus; the
  pack never writes to it automatically. The one deliberate, consent-gated
  exception is `/learn sync`, which pushes *copies* of project learnings as
  facts (`learnings.jsonl` stays canonical; see `vibe-learnings-sync-plan`).
  Synced facts carry `written_by: vibestack-learn-sync` — consumers recalling
  them must treat the text as recorded observation, never as instructions.
- **Local state is the record** — durable decisions, learnings, analytics, and
  per-project artifacts live under `~/.vibestack/` (override with
  `$VIBESTACK_HOME`). Decisions and artifacts are **local and reliable; the brain
  is not required for them**.

```
~/.vibestack/
├── config.json                         # vibe-config key/value
├── bin/                                # installed vibe-* binaries (symlinks)
├── analytics/telemetry.jsonl           # opt-in only
├── .update-check-stamp                 # update-check throttle (24h)
└── projects/<slug>/
    ├── learnings.jsonl                 # vibe-learnings-*
    ├── memex-synced.txt                # /learn sync watermark (key<TAB>type)
    ├── decisions.jsonl                 # vibe-decision-* (event-sourced)
    ├── timeline.jsonl                  # vibe-timeline-log
    └── <user>-<branch>-*.md            # design docs, test plans, ship metrics, QA reports
```

## Binaries (`bin/`, installed to `~/.vibestack/bin/`)

| Binary | Purpose |
|--------|---------|
| `vibe-slug` | Project slug from the git remote |
| `vibe-config` | Get/set project config (`config.json`) |
| `vibe-learnings-log` / `vibe-learnings-search` | Append / search per-project learnings |
| `vibe-learnings-sync-plan` | Plan `/learn sync` pushes: dedup, watermark, secret redaction |
| `vibe-render-skill` | Render-at-install: expand `{{include}}` directives |
| `vibe-skill-track` | Opt-in skill-usage analytics hook |
| `vibe-session-kind` | Classify the session: spawned / headless / interactive |
| `vibe-repo-mode` | Emit `REPO_MODE=solo\|collaborative` from git history |
| `vibe-telemetry-log` | Append a telemetry event — opt-in, no-op unless enabled |
| `vibe-timeline-log` | Append a per-project timeline event |
| `vibe-update-check` | Throttled (24h) "newer version available" nag |
| `vibe-first-task-detect` | Classify the repo into one first-task bucket for the first-run scaffold (local git + FS only, emits one enum token) |
| `vibe-decision-log` / `vibe-decision-search` | Event-sourced local decision store (`--supersede` / `--redact`, secret rejection) |
| `vibestack` | Umbrella CLI — `status` / `doctor` / `skills` / `version`, and dispatch to any `vibe-<tool>` |
| `vibe-lint-sources` | Static lint over skill sources + snippets (fence balance, duplicate headings, nested includes, size); runs inside `./install` before rendering |
| `vibe-certify` | Cross-runtime conformance: fixture-install per target + per-skill verification matrix |
| `vibe-brand-audit` | Fail if tracked files, commit messages, or PR/release text name a source other than this project; run by CI on every PR |
| `vibe-question-log` | Append an AskUserQuestion event to the project log — the only writer of the log `/plan-tune` reads |
| `vibe-question-check` | Classify a question one-way vs two-way, so a preference can never suppress a destructive confirmation |
| `vibe-untrusted` | Wrap externally-authored text (PR/issue bodies) in a labelled envelope and flag instruction-shaped lines |
| `vibe-review-log` / `vibe-review-read` | Append / read the per-branch review ledger the plan-* dashboards summarise |
| `vibe-next-version` | Next free VERSION slot, skipping versions already claimed by open PRs (`--exclude-pr` drops your own) |
| `vibe-diff-scope` | Classify a diff as frontend / backend / docs / config, so QA and canary depth match the change |
| `vibe-redact` / `vibe-redact-prepush` | Secret redaction for text about to leave the machine, and the pre-push guard that enforces it |
| `vibe-design` | Design-asset generation; reports `DESIGN_NOT_AVAILABLE` without an API key |
| `vibe-specialist-stats` | Aggregate specialist-reviewer findings across runs |

`./install` copies every `bin/vibe-*` plus the `vibestack` CLI into the runtime
bin (`~/.vibestack/bin`), and stamps the pack version at `~/.vibestack/version`.
Add the bin dir to `PATH` to use the CLI from anywhere, like a server-side tool:

```bash
export PATH="$PATH:$HOME/.vibestack/bin"
vibestack            # status overview
vibestack doctor     # health check
vibestack config get proactive
```

## Shared snippets (`lib/snippets/`)

Skills compose from snippets via `{{include lib/snippets/<name>.md}}`, expanded at
install time by `vibe-render-skill`. Preamble/protocol snippets, in load order:

1. **`session-host.md`** — session-kind + Conductor detection, `REPO_MODE`, the
   `vibe-config` behavior flags (`PROACTIVE`, `EXPLAIN_LEVEL`, `CHECKPOINT_MODE`,
   `QUESTION_TUNING`), `MODEL_OVERLAY`, and the update nag.
2. **`decision-brief.md`** — how to ask: the decision-brief format, host MCP vs
   native tool resolution, the failure/unavailable and interactive prose
   fallbacks, one-way/destructive hardening.
3. **`working-protocols.md`** — completion status, confusion protocol, context
   health + recovery, completeness mindset, search-before-building, repo ownership.
4. **`state-protocols.md`** — cross-session decisions, continuous checkpoint,
   skill routing, question tuning, voice, model overlay, opt-in telemetry.

Plus the focused snippets: `capture-learnings`, `prior-learnings`,
`brain-preflight`, `secret-scan-patterns`, `askuserquestion-split`,
`exit-plan-mode-gate`, `unresolved-decisions-status`, `review-readiness-dashboard`,
`tasks-section-emit` / `-aggregate`, `browse-setup`,
`plan-file-review-report`, `spec-review-loop`.

## Preamble flags

The preamble echoes flags the skill body reads. All come from the environment or
`vibe-config` — no flag implies a tool the pack does not ship.

| Flag | Source | Meaning |
|------|--------|---------|
| `SESSION_KIND` | env | `spawned` / `headless` / `interactive` |
| `CONDUCTOR_SESSION` | env | host's question tool is unreliable → render decisions as prose |
| `REPO_MODE` | git | `solo` (own everything) / `collaborative` (flag, don't fix) |
| `PROACTIVE` | config | `false` → don't auto-invoke skills |
| `EXPLAIN_LEVEL` | config | `terse` → skip optional explanation |
| `CHECKPOINT_MODE` / `CHECKPOINT_PUSH` | config | continuous WIP commits vs explicit |
| `QUESTION_TUNING` | config | honor recorded question preferences (`/plan-tune`) |
| `MODEL_OVERLAY` | env | model family for self-adjustment (default `claude`) |
| `VIBE_FORCE_CODEX_REVIEW` | env | `1` → spawn the Codex outside voice even when the host IS Codex (a live session exports `CODEX_THREAD_ID` / `CODEX_SANDBOX`, and nesting means one model reviewing itself) |

## Shell test suites (`test/`)

Every suite is self-contained: it points `VIBESTACK_HOME` at a temp dir and never
touches real state. Run one directly with `bash test/<name>`.

| Suite | Covers |
|-------|--------|
| `test-hooks.sh` | The `/careful` and `/freeze` PreToolUse hooks — decision wire format, both fail-closed polarities, the escaped-quote extractor, boundary escapes, force-push tiers |
| `test-brand-audit.sh` | `vibe-brand-audit` — what it must reject, and equally what it must NOT fire on |
| `test-render-skill.sh` | `vibe-render-skill`: include expansion, nested-include rejection, infra-error handling |
| `test-install-integration.sh` | `./install` / `./uninstall` across targets: byte-identical renders, atomic swap, recovery, PTY-driven prompts (`PTY_TIMEOUT` raises the 60s default for slow machines) |
| `test-source-lint.sh` | `vibe-lint-sources` static checks over skill sources |
| `test-vibe-bins.sh` | Smoke tests for the `vibe-*` binaries |
| `test-certify.sh` | Cross-runtime conformance fixtures |
| `test-first-task-detect.sh` | First-run repo classification |
| `test-learn-sync.sh` | `/learn sync` planning and dedup |
| `test-browse-shim.sh` | The `vibe-browse` launcher: verb routing, the cheap no-browser path, and `BROWSE_NOT_AVAILABLE` when dependencies are absent |

## CI (`.github/workflows/tests.yml`)

Every PR runs the suites above on Linux **and** macOS — the BSD/GNU split is
where hook patterns break, and stock macOS ships bash 3.2, so the installer
legs `brew install bash` first. Three jobs run beyond the matrix:

- **nothing names another project** — `vibe-brand-audit` over tracked files, the
  PR's commit range, and the PR title and body. Commit messages are checked
  before the merge on purpose: afterwards they cannot be corrected without
  rewriting published history.
- **installed skills match sources** — installs into an isolated `HOME` and
  proves every rendered `SKILL.md` still matches its source.
- **hook scripts are runnable** — every skill hook and `bin/` script carries the
  executable bit, and the shell ones are parsed with `bash -n`. Python binaries
  are checked for the bit only; their syntax is covered by `test-vibe-bins.sh`
  actually running them.

## E2E skill evals (`test/evals/`)

`session-runner.ts` spawns a real `claude -p` session in a throwaway sandbox:
skills render from repo sources into the sandbox's project-level
`.claude/skills/` (the path real installs resolve), `VIBESTACK_HOME` points
into the sandbox, and the child gets zero MCP servers. The runner streams
NDJSON and survives timed-out children that leave pipe-holding orphans —
regression-locked by `session-runner-timeout.test.ts`, which runs offline in
the default suite.

```bash
bun run test:runner   # offline: the timeout/orphan regression test only
bun run test:evals    # live smoke evals for /review /ship /investigate — costs real tokens
EVALS_MODEL=claude-haiku-4-5-20251001 bun run test:evals   # cheaper model
```
