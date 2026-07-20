# vibestack internals

How the pack works under the skills: the binaries, the shared snippets, the
preamble flags, and the memory architecture. For the skill catalogue see
[`skills.md`](skills.md); for the spec-compatibility matrix see
[`agent-skills-compatibility-audit.md`](agent-skills-compatibility-audit.md).

## Architecture: brain vs. local state

vibestack splits durable knowledge the same way reference does:

- **memex is the brain** — a hosted Postgres + pgvector MCP server. It is the
  **read-only semantic-recall** layer: skills query it for product/goal/prior
  context (`mcp__memex__search`, `entity_recall`, …). The agent never *writes* to
  memex; it indexes its own corpus.
- **Local state is the record** — durable decisions, learnings, analytics, and
  per-project artifacts live under `~/.vibestack/` (override with
  `$VIBESTACK_HOME`). Decisions and artifacts are **local and reliable; the brain
  is not required for them** — the same split the reference uses.

```
~/.vibestack/
├── config.json                         # vibe-config key/value
├── bin/                                # installed vibe-* binaries (symlinks)
├── analytics/telemetry.jsonl           # opt-in only
├── .update-check-stamp                 # update-check throttle (24h)
└── projects/<slug>/
    ├── learnings.jsonl                 # vibe-learnings-*
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
| `vibe-render-skill` | Render-at-install: expand `{{include}}` directives |
| `vibe-skill-track` | Opt-in skill-usage analytics hook |
| `vibe-session-kind` | Classify the session: spawned / headless / interactive |
| `vibe-repo-mode` | Emit `REPO_MODE=solo\|collaborative` from git history |
| `vibe-telemetry-log` | Append a telemetry event — opt-in, no-op unless enabled |
| `vibe-timeline-log` | Append a per-project timeline event |
| `vibe-update-check` | Throttled (24h) "newer version available" nag |
| `vibe-first-task-detect` | Classify the repo into one first-task bucket for the first-run scaffold (local git + FS only, emits one enum token) |
| `vibe-decision-log` / `vibe-decision-search` | Event-sourced local decision store (`--supersede` / `--redact`, secret rejection) |
| `vibe-parity-audit` | Maintainer tool — prove skills still mirror reference (runs from the repo, not installed) |

`./install` symlinks every `bin/vibe-*` except `vibe-parity-audit`.

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
`tasks-section-emit` / `-aggregate`, `browse-setup`.

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
