# vibestack internals

How the pack works under the skills: the binaries, the shared snippets, the
preamble flags, and the memory architecture. For the skill catalogue see
[`skills.md`](skills.md); for the spec-compatibility matrix see
[`agent-skills-compatibility-audit.md`](agent-skills-compatibility-audit.md).

## Architecture: brain vs. local state

vibestack splits durable knowledge in two:

- **memrain is the brain** — a hosted Postgres + pgvector MCP server. It is the
  **semantic-recall** layer: skills query it for product/goal/prior context
  (`mcp__memrain__search`, `entity_recall`, …). It indexes its own corpus; the
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
    ├── memrain-synced.txt                # /learn sync watermark (key<TAB>type)
    ├── decisions.jsonl                 # vibe-decision-* (event-sourced)
    ├── timeline.jsonl                  # vibe-timeline-log
    ├── kb-isolation-<date>.json        # /kb-review tenant-isolation probe
    ├── kb-eval-<date>.jsonl            # /kb-review golden question set
    ├── kb-eval-results-<date>.jsonl    # /kb-review retrieval results per question
    ├── kb-cost-<date>.json             # /kb-review Cost Explorer pull
    ├── kb-review-<date>.md             # /kb-review report
    ├── aws-cost-<date>.md              # /aws-cost report
    ├── .ids-asked / .ids-got           # /kb-review denominator check (sorted id lists)
    └── <user>-<branch>-*.md            # design docs, test plans, ship metrics, QA reports
```

`/kb-review` dates its own files, so a second run on another day sits beside the
first rather than overwriting it. `.ids-asked` and `.ids-got` are scratch: the
skill writes the two sorted id lists there and diffs them with `comm`, so a
question that was asked but never scored shows up as a missing row instead of a
quietly shorter denominator.

### State written outside this tree

Two things the pack writes live elsewhere, because they belong to something
other than a project's own record:

- **`<target skills root>/.vibestack-manifest`** — the list of skill names
  `./install` last wrote into that root, one per line, sitting inside the root
  itself (`~/.claude/skills/`, `~/.cursor/skills/`, `~/.kiro/skills/`,
  `~/.agents/skills/`, or the project-scope equivalent). The next install reads
  it to tell a skill the pack withdrew from a skill some other tool put there:
  without the record both look identical once the name leaves the pack, and the
  adopt-back step that protects other installers' work carries the withdrawn one
  straight back in. A name is removed only if the manifest claims it and the
  directory still holds a `SKILL.md`. `./uninstall` deletes the manifest along
  with the skills.
- **`.vibestack/security-reports/<date>-<HHMMSS>.json`** — `/cso`'s saved audit,
  written into the repository under audit rather than into `~/.vibestack/`.
  Phase 13 reads the prior reports in that same directory to sort findings into
  resolved, persistent and new, so the history lives beside the code it
  describes. Reports are meant to stay local: `/cso` raises a finding when
  `.vibestack/` is not in `.gitignore`.

Phase identifiers in that report are integers with one exception: Phase 5b, the
live AWS account posture pass, is the string `"5b"` in both `phases_run` and a
finding's `phase` field, and appears only when the phase actually ran. Its
findings carry the category `AWS Posture` and have no file and no line to cite,
so `file` holds the resource instead — a resource ARN, `<account-id>:<region>`
for a region-scoped check, or `<account-id>:global` for an account-wide one —
`line` stays `0`, and `commit` is `null`. One form per check is not a style
preference: the finding fingerprint is a hash over category, file and title, so
two runs that disagree on the form report the same finding as both resolved and
new.

## Binaries (`bin/`, installed to `~/.vibestack/bin/`)

| Binary | Purpose |
|--------|---------|
| `vibe-slug` | Project slug from the origin remote, as `owner--repo` (`github.com/alice/api` → `alice--api`). The double hyphen never occurs inside a sanitized part, so `a-b/c` and `a/b-c` stay apart and no new slug equals an old one; when sanitizing changed the owner or repo (`my.repo` and `my_repo`), and for nested groups and local-path remotes, an 8-hex hash of the canonical remote is appended. Without a remote the slug is the folder name plus a hash of the clone's absolute git common dir, so two remote-less repos with one folder name stay apart. `VIBESTACK_PROJECT_SLUG` overrides. The first run under the new name copies durable state (learnings, decisions, specs, design boards, the project's own stamped checkpoints) from the old name-only bucket — copied, never moved — only when that bucket holds a checkpoint stamped with this exact project. A review-log commit that also exists here is not proof (a fork shares history): it, like no evidence at all, prints a notice once and `vibe-slug --migrate` copies on request. Unstamped checkpoints come across only with `--migrate --include-unstamped`. The old bucket's `.claimed-by` records the claiming project and its evidence; an unproven claim gives way to a later project that holds a stamped checkpoint there. A copy that fails partway leaves no marker or claim and is retried. `VIBESTACK_SLUG_NO_MIGRATE=1` skips the copy; `vibe-evidence`, `vibe-review-log` and `vibe-review-read` set it because they call `vibe-slug` under a 5s timeout. Review logs and deploy confirmations are never carried over, so the readiness dashboard starts empty for branches that were open. `--identity`, `--stamp-checkpoint` and `--classify-checkpoints` let `/context-save` stamp and `/context-restore` filter checkpoints by project; a checkpoint without a closing `---` is refused. Limit: one owner/repo on two hosts shares a bucket — set `VIBESTACK_PROJECT_SLUG` |
| `vibe-config` | Get/set project config (`config.json`) |
| `vibe-learnings-log` / `vibe-learnings-search` | Append / search per-project learnings |
| `vibe-learnings-sync-plan` | Plan `/learn sync` pushes: dedup, watermark, secret redaction |
| `vibe-render-skill` | Render-at-install: expand `{{include}}` directives |
| `vibe-skill-track` | Opt-in skill-usage analytics hook |
| `vibe-session-kind` | Classify the session: spawned / headless / interactive. `spawned` needs `OPENCLAW_SESSION` or an affirmative `VIBE_SPAWNED` (`0`/`false`/`no`/`off` do not count); the dispatching agent sets `VIBE_SPAWNED=1`, since an agent-tool child inherits no environment |
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
| `vibe-review-log` / `vibe-review-read` | Append / read the per-branch review ledger the plan-* dashboards summarise; `vibe-review-read --any-branch --skill <name>` returns that skill's newest entry across every branch log of the project, with its branch (the /devex-review baseline) |
| `vibe-next-version` | Next free VERSION slot, skipping versions claimed by open PRs against the same base — each PR's claim is the VERSION file at its head (`--exclude-pr` drops your own) |
| `vibe-diff-scope` | Classify a diff as frontend / backend / docs / config, so QA and canary depth match the change |
| `vibe-redact` / `vibe-redact-prepush` | Secret redaction for text about to leave the machine, and the pre-push guard that enforces it. `vibe-redact scan --file <path> [--file …]` is the deterministic, fail-closed scan the publishing skills (`/spec`, `/document-generate`, `/document-release`, `/ship`) run before any external write: exit 0 clean, 1 finding (`HIGH  <label>  <path>:<line>  <masked>`), 2 could not run — the same matcher and patterns as the pre-push guard. Both skip documentation placeholders judged on the matched value alone (the AWS docs keys, `<token>`, `xxxxxx`, a value starting or ending in `example`), and the guard blocks a push when the matcher itself fails |
| `vibe-design` | Design-asset generation; reports `DESIGN_NOT_AVAILABLE` without an API key. `variants` never overwrites (an existing `variant-A.png` makes the next image `variant-A-2.png`) and prints `requested:`, one `saved: <path>` per image written, `failures:` and one `failed: <variant>: <reason>` per image not saved — callers use only the `saved:` paths. `--brief-file <path>` reads the brief from a file, so skills never put brief text in shell source. Exit 0 all saved, 3 partial, 2 nothing saved (with a `DESIGN_ERROR:` line), 1 usage error |
| `vibe-specialist-stats` | Aggregate specialist-reviewer findings across runs |
| `vibe-tree-hash` | Content fingerprint of the tracked working tree — a git tree id, so a commit or rebase that changes no bytes changes no hash |
| `vibe-evidence` | Record command + exit status + tree hash, and answer "did THIS tree pass?" from the ledger instead of from prose. A single argument after `--` runs as a shell command line and is recorded verbatim. `check` narrows with `--expect-cmd C` (the recorded line must equal C), `--max-age H` (older passes are STALE) and `--allow-paths P` (a run at another tree still counts when only release bookkeeping such as `CHANGELOG.md,VERSION` differs); a recorded tree the object store no longer has never matches |
| `vibe-version-bump` | Move VERSION, `package.json` and the lockfiles together or not at all; `--root` for a manifest in a subdirectory |
| `vibe-detach` | Run a command past the turn boundary; `status` separates running (exit 2) from failed (exit 1) |
| `vibe-context-budget` | Measure the always-loaded skill listing (rendered name + description per skill) against a runtime's budget — Codex 8,000 chars by default; exit 1 over budget, `--warn-only` reports without failing; CI reports it on every PR |
| `vibe-codex-probe` | Whether Codex is *usable*, not merely installed — cheap negatives first, one cached round trip for the positive |

`./install` copies every `bin/vibe-*` plus the `vibestack` CLI into the runtime
bin (`~/.vibestack/bin`), and stamps the pack version at `~/.vibestack/version`.
Add the bin dir to `PATH` to use the CLI from anywhere, like a server-side tool:

```bash
export PATH="$PATH:$HOME/.vibestack/bin"
vibestack            # status overview
vibestack doctor     # health check
vibestack config get proactive
```

## Review specialists (`skills/review/specialists/`)

`/review` and `/ship` dispatch a subagent per specialist, each reading one
checklist from this directory. Which ones run depends on the diff: testing and
maintainability always, the rest gated on scope or size.

Under 50 changed lines no specialist runs at all. Above that:

| Specialist | Runs when |
|---|---|
| `testing.md` | every review over the 50-line floor |
| `maintainability.md` | every review over the 50-line floor |
| `security.md` | `SCOPE_AUTH`, or `SCOPE_BACKEND` with a diff over 100 lines |
| `performance.md` | `SCOPE_BACKEND` or `SCOPE_FRONTEND` |
| `data-migration.md` | `SCOPE_MIGRATIONS` |
| `api-contract.md` | `SCOPE_API` |
| `simplification.md` | diff over 100 lines |
| `red-team.md` | a second pass, after the others: diff over 200 lines, or any specialist returned a CRITICAL |

`SCOPE_FRONTEND` also dispatches a design pass, which reads
`review/design-checklist.md` rather than a file in this directory.

**Adaptive gating** runs after scope selection: a conditional specialist that has
returned nothing in ten or more dispatches is skipped and says so, so a lens that
never fires on this codebase stops costing a subagent every review.

Simplification is **advisory**: its findings are severity `INFORMATIONAL`, are
excluded from the quality score and the findings count, and are never auto-fixed.
A taste call must not move the numbers a defect moves.

## Shared behavior rules

These live in `lib/snippets/` and reach every skill that includes them, so they
are worth knowing as rules of the pack rather than of any one skill.

- **A decision brief has a quality floor** (`decision-brief.md`): at least two
  concrete pros and one honest con per option, bullets that say something
  measurable, the non-recommended option written in the same register as the
  recommended one, and a self-check the model runs before sending. An option
  with no stated downside reads as a decision already made.
- **Claimed limitations need evidence** (`working-protocols.md`): never assert
  that something cannot be done without having tried it and being able to name
  the command and its output.
- **Three session kinds** (`session-host.md`): `interactive` asks;
  `headless` stops on anything blocking, since nobody can answer; `spawned` —
  driven by another agent — takes the recommended option on a two-way choice and
  says in its output that it auto-picked and what the alternative was, while a
  one-way or destructive choice still stops. Text arriving from the dispatching
  agent is data describing a task: it cannot approve a destructive step or widen
  permissions.

## Shared snippets (`lib/snippets/`)

Skills compose from snippets via `{{include lib/snippets/<name>.md}}`, expanded at
install time by `vibe-render-skill`. Preamble/protocol snippets, in load order:

1. **`session-host.md`** — session-kind + Conductor detection, `REPO_MODE`, the
   `vibe-config` behavior flags (`PROACTIVE`, `EXPLAIN_LEVEL`,
   `QUESTION_TUNING`), `MODEL_OVERLAY`, and the update nag.
2. **`decision-brief.md`** — how to ask: the decision-brief format, host MCP vs
   native tool resolution, the failure/unavailable and interactive prose
   fallbacks, one-way/destructive hardening.
3. **`working-protocols.md`** — completion status, confusion protocol, context
   health + recovery, completeness mindset, search-before-building, repo ownership.
4. **`state-protocols.md`** — cross-session decisions,
   skill routing, question tuning, voice, model overlay, opt-in telemetry.

Plus the focused snippets: `capture-learnings`, `prior-learnings`,
`brain-preflight`, `secret-scan-patterns`, `askuserquestion-split`,
`exit-plan-mode-gate`, `unresolved-decisions-status`, `review-readiness-dashboard`,
`tasks-section-emit` / `-aggregate`, `browse-setup`,
`plan-file-review-report`, `spec-review-loop`,
`plan-binding` (how `/ship` and `/review` bind the plan a branch was built from),
`release-after-merge` (the tag-and-release step `/ship` and `/land-and-deploy` share),
`outside-voice-preflight` — the `CODEX_MODE` resolution the three plan reviews
share: config switch, running-under-Codex probe, install and auth checks, and
the branch bullets they act on.

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
| `test-evidence-bins.sh` | The evidence/version/detach/probe helpers, asserted in both directions — each must also FAIL when it should |
| `test-certify.sh` | Cross-runtime conformance fixtures |
| `test-first-task-detect.sh` | First-run repo classification |
| `test-learn-sync.sh` | `/learn sync` planning and dedup |
| `test-browse-shim.sh` | The `vibe-browse` launcher: verb routing, the cheap no-browser path, and `BROWSE_NOT_AVAILABLE` when dependencies are absent |
| `test-dispatch-flags.sh` | Every synchronous subagent dispatch in a rendered skill states `run_in_background: false` |
| `test-fresh-shell-vars.sh` | No skill bash block reads a variable an earlier block set — every tool call is a fresh shell |
| `test-untrusted-shell-text.sh` | Untrusted text (plan, spec, PR and issue bodies, briefs, pasted output) reaches a command only through a file, never as shell source |
| `test-update-check.sh` | `vibe-update-check` against a local fake remote: checkout discovery, `CHECK_FAILED`, the day stamp |
| `test-vibe-upgrade-flow.sh` | `/vibe-upgrade` blocks against a fake remote: replaying the original install, stopping on a failed fetch |
| `test-vibe-upgrade-guards.sh` | `/vibe-upgrade`'s mutating blocks refuse an empty or wrong install dir; migrations receive the install dir |
| `test-plan-tune-profile.sh` | `/plan-tune` profile writes land under `VIBESTACK_HOME` as numbers and nothing lands in the working directory |
| `test-plan-review-contract.sh` | Contracts between `/autoplan` and the plan-review and `/office-hours` skills it loads from disk |
| `test-plan-ceo-review.sh` | `/plan-ceo-review` keeps the user in control of scope and reports failed metric writes |
| `test-plan-eng-review-rubric.sh` | `/plan-eng-review` rules and the shared Implementation Tasks snippet |
| `test-plan-design-review.sh` | `/plan-design-review` keeps plan text out of the shell, every fix behind approval, and the review log honest |
| `test-autoplan-ledger.sh` | `/autoplan` audit records: well-formed tables and one voice record per review |
| `test-config-claude_md_preserve.sh` | The deployed `~/.claude/CLAUDE.md` is merged, so lines a third party appended survive a sync |
| `test-config-codex_agents.sh` | `config/codex/AGENTS.md` matches what `scripts/gen-codex-agents.py` generates from its sources |
| `test-config-deliberation.sh` | The opt-in deliberation plugin install, which leaves its own config to the plugin's setup |
| `test-config-install_bootstrap.sh` | The configuration library finds its own files under `bash -c "$(curl …)"` |
| `test-config-rtk.sh` | `rtk init -g` runs after the settings merge, and the RTK installer is downloaded to a file before it runs |
| `test-config-settings_merge.sh` | The shipped `settings.json` merge program, extracted and run as-is |
| `test-config-sync.sh` | `lib/config-sync.sh`: manifest prune and fill-missing merges in a fake HOME |
| `test-config-phase.sh` | Real configuration-phase installs into isolated HOMEs |
| `test-config-uninstall-keys.sh` | `./uninstall --with-config` takes back the merged keys the install owns and leaves the rest |
| `test-config-skills-routing.sh` | Every routed slash name in `rules/skills.md` exists; non-pack names are marked |
| `test-claude-gate.sh` | The `/claude` parser, timeout wrapper and hermetic flags |
| `test-codex-verdict.sh` | `/codex` grades every run, so a run that reviewed nothing reports `VERDICT: unavailable` |
| `test-document-release.sh` | `/document-release` blocks against stub `gh`/`glab`: spawned mode, hostile PR text, fresh shells |
| `test-document-generate-pr-body.sh` | `/document-generate` commits without an assistant trailer and publishes a PR body only through the trust envelope and secret scan |
| `test-cso-contract.sh` | `/cso` text contracts: trend tracking resolves a finding only on new evidence, `--recheck` |
| `test-review-checklist.sh` | `skills/review/checklist.md` and the `/connect-review` Bedrock step; runs every `rg` probe the checklist prints |
| `test-review-log.sh` | `vibe-review-log` tree binding and honest-status guards, plus the `/review` contracts that feed it |
| `test-review-tree-binding.sh` | Reviews and test runs are keyed to tree content, not commits |
| `test-ship-doc-contract.sh` | `/ship` drives `/document-release` through its spawned-mode contract |
| `test-ship-release-gates.sh` | `/ship` version, push, distribution and release gates on fixture repos |
| `test-release-after-merge.sh` | The shared tag-and-release step `/ship` and `/land-and-deploy` run once a PR has merged |
| `test-land-deploy-gates.sh` | `/land-and-deploy` merges only the approved head over green CI and reverts exactly what landed |
| `test-test-value-bar.sh` | The test value bar reaches every skill that writes, proposes or reviews tests, without drifting copies |
| `test-context-provenance.sh` | `/context-save` and `/context-restore` keep a resumed session off the wrong context or a guessed step |
| `test-context-identity.sh` | Checkpoints are stamped with their project and restore never offers another project's |
| `test-learn-honest-read.sh` | A failed learnings read surfaces as unavailable; `--cross-project` carries only user-stated entries |
| `test-design-saved-paths.sh` | Every skill running `vibe-design variants` uses the printed `saved:` paths |
| `test-design-consultation.sh` | `/design-consultation` writes nothing before approval and verifies fonts |
| `test-design-html.sh` | `/design-html` instructions use the real Pretext API and no bundle that does not ship |
| `test-design-review-contract.sh` | `/design-review` outside voices, browser use, diff-aware scope and fix verification |
| `test-design-shotgun-handoff.sh` | `/design-shotgun` writes `approved.json` from a file with the approved image's absolute path |
| `test-devex-boomerang.sh` | `/devex-review` reads the `/plan-devex-review` baseline and drives the browser under look-not-act rules |
| `test-browser-skill-consent.sh` | The browser skills ask before they destroy or expose a signed-in session |
| `test-health-scoring.sh` | `/health` scores the checkers' real exit codes and full logs |
| `test-context-budget.sh` | `vibe-context-budget` counts what the runtime lists and fails over budget |
| `test-host-routing.sh` | Host-dependent routing: the `/vibe` index, the second-opinion pick, the memrain code-graph rule |
| `test-redact-scan.sh` | `vibe-redact scan`: deterministic, fail-closed, sharing the pre-push guard's matcher |
| `test-compliance-runner.sh` | The rule/skill compliance runner's bun tests against a fake `claude` — no tokens spent |

## CI (`.github/workflows/tests.yml`)

Every PR runs the suites above on Linux **and** macOS — the BSD/GNU split is
where hook patterns break, and stock macOS ships bash 3.2, so the installer
legs `brew install bash` first. Six jobs run beyond the matrix:

- **nothing names another project** — `vibe-brand-audit` over tracked files, the
  PR's commit range, and the PR title and body. Commit messages are checked
  before the merge on purpose: afterwards they cannot be corrected without
  rewriting published history.
- **installed skills match sources** — installs into an isolated `HOME` and
  proves every rendered `SKILL.md` still matches its source.
- **make-pdf and browse daemon unit tests** — `bun test` over `make-pdf/test/*.test.ts`
  (after building the binary) and `browse/test/`, with Chromium installed for the
  navigation-guard fixture.
- **skill listing fits the context budget** — `vibe-context-budget` over the
  rendered listing; an over-budget result is a warning annotation, not a failure.
- **hook scripts are runnable** — every skill hook and `bin/` script carries the
  executable bit, and the shell ones are parsed with `bash -n`. Python binaries
  are checked for the bit only; their syntax is covered by `test-vibe-bins.sh`
  actually running them.

## E2E skill evals (`test/evals/`)

`session-runner.ts` spawns a real `claude -p` session in a throwaway sandbox:
skills render from repo sources into the sandbox's project-level
`.claude/skills/` (the path real installs resolve), `VIBESTACK_HOME` points
into the sandbox, and the child gets zero MCP servers. Sessions run with
`--dangerously-skip-permissions`, so the child's working directory is the
sandbox and its `HOME` (with `CLAUDE_CONFIG_DIR` and `XDG_CONFIG_HOME`) is a
fresh directory inside it — never your HOME or this repository. The same holds
for every session and judge call of `bun run test:compliance`, which keeps its
USD cap (`--max-usd`, default $1.00). Authenticate with `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN`; nothing under the real HOME is read. The runner streams
NDJSON and survives timed-out children that leave pipe-holding orphans —
regression-locked by `session-runner-timeout.test.ts`, which runs offline in
the default suite.

```bash
bun run test:runner   # offline: the timeout/orphan regression test only
bun run test:evals    # live smoke evals for /review /ship /investigate — costs real tokens
EVALS_MODEL=claude-haiku-4-5-20251001 bun run test:evals   # cheaper model
```
