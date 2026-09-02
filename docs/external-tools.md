# External tools

vibestack ships its own `vibe-*` binaries (`docs/internals.md` lists them). A handful of skills depend on **external tools that vibestack does not bundle**. Those skills detect availability at runtime and degrade to text-only operation when the dependency is missing.

This page documents the gap honestly so you can decide whether to install the dependency or skip the affected skills.

---

## Supported agent runtimes

vibestack installs into four agent runtimes that all implement
the [Agent Skills open standard](https://agentskills.io/specification):

- **Claude Code** — `~/.claude/skills/`. Full feature support (hooks, subagents).
- **Cursor** — `~/.cursor/skills/`. Track B verified 2026-05-09 (Cursor
  `2026.05.07-42ddaca`): hook-bearing skills install but their hooks do **not**
  fire, though Cursor's own shell-permission sandbox blocks `rm -rf`
  independently. Procedure: `docs/hook-verification.md`.
- **Kiro** — `~/.kiro/skills/`. Track B verified 2026-05-09 (Kiro CLI 2.2.2):
  hook-bearing skills install but their hooks do **not** fire, and unlike Cursor
  there is no native sandbox behind them — destructive commands run unimpeded
  and the safety skills degrade to LLM instruction-following.
- **Codex CLI** — `~/.agents/skills/` (user scope), `.agents/skills` (repo
  scope). `~/.codex` holds config only and never receives skills; a superseded
  copy there is pruned by name. Skills are referenced as `$name` inside a normal
  message, or triggered implicitly from their `description` — `/` is reserved for
  Codex's own commands and does not complete skill names.
  Runtime hooks unverified — same status as Cursor/Kiro before their Track B pass.

Other Agent-Skills-compatible runtimes (Gemini CLI, Antigravity, OpenCode,
Windsurf) are not yet a `--target=` option. The SKILL.md files would work; the
only blocker is one row per map in the target registry in `./install`.

---

## gh CLI

**Required by:** `/address-pr-review` and `/pr-summary` outright. Fourteen more
skills call it when the remote is GitHub and fall through to `glab` or plain git
when it is not: `/autoplan`, `/canary`, `/codex`, `/devex-review`,
`/document-generate`, `/document-release`, `/land-and-deploy`,
`/plan-ceo-review`, `/plan-design-review`, `/plan-devex-review`, `/qa`,
`/retro`, `/review`, `/ship`. Four more — `/benchmark`, `/landing-report`,
`/spec`, `/unslop` — reach for it on one path each and carry on without it.

**What it is:** GitHub's own command-line client, authenticated once with `gh
auth login`. Skills read pull requests, review threads, issues and workflow-run
logs through it, and write PR bodies, titles, thread replies and issues back.
Nothing here calls the REST or GraphQL API with a token of its own: the
credential is whatever `gh` already holds, and no skill reads it.

**Status:** vibestack does **not** bundle it, and does not install or
authenticate it. Fourteen of the twenty skills above preflight with `gh auth
status` — not the same fourteen as the platform-detecting group, since
`/document-generate` skips the check and `/spec` makes it. `/ship` and `/review`
read it to pick a platform and fall through when it fails, `/spec` to decide
whether to run its duplicate-issue search, `/land-and-deploy` to stop before it
tries to merge. The two skills that require `gh` do not preflight at all — the
three helper scripts under `skills/address-pr-review/bin/` gate on
`command -v gh` and bail out when the binary is missing, and `/pr-summary` goes
straight to `gh pr view`.

**If you don't have it:**

- `/address-pr-review` stops. Its three helper scripts under
  `skills/address-pr-review/bin/` all print `gh CLI not found — install it and
  run 'gh auth login'` and exit non-zero — 2 from `pr-threads.sh` and
  `pr-ci-failures.sh`, 1 from `pr-thread-reply.sh`. Every thread they fetch,
  reply to or resolve is a `gh api graphql` call. That is also why the skill is
  GitHub-only — review threads resolve through GraphQL, and `glab` has no
  equivalent.
- `/pr-summary` stops too. Reading the PR, its commits and its diff, then
  writing the description and title back, is `gh pr view` / `gh pr diff` /
  `gh pr edit` end to end, with no GitLab path.
- The fourteen platform-detecting skills fall through their Step 0 chain —
  `glab` when the remote is GitLab, then `git symbolic-ref`, then `origin/main`
  or `origin/master` — and keep working against that base branch. `/ship`,
  `/document-release`, `/land-and-deploy` and `/review` go further and read or
  write the PR itself; those parts are what a missing `gh` costs on a GitHub
  remote.
- `/landing-report` reports `OFFLINE — queue-awareness unavailable`: without a
  view of open PRs it cannot say which VERSION slots are claimed, and
  `vibe-next-version` behind it falls back to local arithmetic.
- `/spec` skips its duplicate-issue search, says so, and at the end prints the
  issue title and body for you to paste into the new-issue form rather than
  filing it.
- `/unslop` loses its PR-number input and its write-back, and still works on
  pasted text or a file path. `/benchmark` falls back to `main` as its diff
  base.

---

## browse daemon

**Required by:** `/browse`, `/open-browser`, `/pair-agent`, `/setup-browser-cookies`

### Bundled stateless shim (since v1.8.4)

`/design-review` no longer surrenders when no daemon is present. vibestack now
ships **`vibe-browse`** — a stateless, Playwright-backed shim under
`skills/browse/` that implements the read-only `$B` verb surface:
`goto`, `screenshot`, `responsive`, `viewport`, `console`, `network`, `perf`,
`js`, `css`, `is`, `text`, `url`, `status`. On first capture it installs
Playwright + Chromium into `~/.vibestack/browse/` (one time), then runs
locally. Each verb is independent — `goto` records the target URL and every
capture re-navigates fresh, so no browser persists between calls.

**What it does NOT do:** cross-call element refs (`@e3`) and the interaction
verbs that need them — `snapshot -i/-a/-D`, `click`, `fill`, `hover`, `upload`,
`dialog` — plus CDP/cookie/tunnel/pairing. Those print `NOT_SUPPORTED:<verb>`;
the consuming skill skips that pass. The interaction-heavy skills below
(`/browse`, `/open-browser`, `/pair-agent`, `/setup-browser-cookies`) still need
the full daemon.

### Full daemon (interaction + CDP)

**What it is:** a persistent headless Chromium daemon that exposes a fast (~100ms) command interface for navigating, screenshotting, asserting, and interacting with web pages.

**Status: bundled.** The daemon source ships in this repo under `browse/`, and
`./install` prepares its dependencies. Skills locate the launcher relative to their
own installed directory — `${CLAUDE_SKILL_DIR}/../browse/bin/vibe-browse`, falling
back to `vibe-browse` on `PATH` — which resolves in both user and project scope and
does not depend on where the checkout lives. There is nothing to drop in by hand.

The one thing that is not vendored is Chromium itself: the launcher fetches Playwright
and a browser into a cache directory on first use. Without `npm` on `PATH` it cannot,
and prints `BROWSE_NOT_AVAILABLE` — the browse-dependent skills then fall back to
text-only checks (curl, basic HTTP) where possible.

**Overriding it:** put your own `vibe-browse` earlier on `PATH` — the launcher falls back to `PATH` when the bundled one is not where it expects.

**If you don't:** the affected skills will skip gracefully and tell you what they couldn't do. Every skill outside this page works fully without the daemon.

---

## aws CLI

**Required by:** `/aws-cost`, `/bedrock-guardrails`, `/kb-review`, `/connect-review`,
`/ai-cost-guard`, and Phase 5b of `/cso`

**What it is:** the `aws` command-line client with credentials that already work on
the machine — a configured profile, an SSO session, or an instance role. These skills
read an account they are pointed at; none of them reads `~/.aws/credentials` itself,
and `/cso` and `/aws-cost` say in as many words that they will never ask you for keys.

**Status:** vibestack does **not** bundle it, and does not install or configure it.
Install it the way your team already does.

**Nothing is written to your account.** No call creates, updates, deletes, attaches,
enables, or purchases. The calls are not all `get`/`list`/`describe`, though:
`/connect-review` reads Lambda logs with `logs filter-log-events`, and `/kb-review`
lists and downloads source documents with `s3 ls` and `s3 cp`, reads collections with
`opensearchserverless batch-get-collection`, and queries the knowledge base itself
with `retrieve` and `retrieve-and-generate`. Two consequences before you scope a
profile: `/kb-review` needs Bedrock retrieve permissions beyond a plain read-only
policy, and its `retrieve-and-generate` pass is billed for model inference like any
other query, so the evaluation costs whatever its question set costs to answer.
`s3 cp` writes to local disk only, never back to the bucket.

**If you don't have it:** nothing hangs or crashes. `/cso` skips its AWS phase
silently when the repository shows no sign of AWS at all; when it does find AWS it
prints `AWS posture: skipped (aws CLI not found)`, or `AWS posture: skipped
(credentials unusable)` with the error text when the CLI is present but
unauthenticated, and finishes its other phases either way.
`/bedrock-guardrails` marks every control that needs live account state as
`N-A (no CLI)` and audits your Terraform and application code instead.
`/aws-cost` prefers the AWS billing MCP tools when the session has them and only
falls back to the CLI; on that path it may ask which profile to use, and stops with a
setup note naming the one it tried rather than guessing.
`/ai-cost-guard` marks every budget and quota line `unknown` and says what to run.
`/connect-review` greps the repository first and asks you for the flow export path or
resource id it still cannot resolve. `/kb-review` falls back to the Terraform and
ingestion code in the repo, asking where the knowledge base lives only if it finds
neither.

---

## MCP inspector (`npx` + `@modelcontextprotocol/inspector`)

**Required by:** `/mcp-review`, for its optional live tool-listing check only

**What it is:** `npx` (from Node) fetching `@modelcontextprotocol/inspector` from npm
on first use, to start the server under review and list the tools it advertises.
`/mcp-review` runs it under `env -i` with a scratch `HOME`, so an exported token cannot
reach the child process — that is credential hygiene, not a sandbox.

**Status:** not bundled, and deliberately not vendored — it is fetched at run time.

**If you don't have it:** the live check is skipped and the rest of the review, which
is static, runs unchanged; the report records the reason on its `Live check:` line.
That check is skipped by design in other cases too, most importantly when the server's
code is untrusted — listing its tools means executing it.

---

## vibe-model-benchmark

**Required by:** `/benchmark-models`

**What it is:** a CLI for running a single prompt against multiple LLM providers (OpenAI, Anthropic, Google, Mistral, Groq, Together, Ollama) and saving structured comparison results.

**Expected location:**

```
~/.vibestack/bin/vibe-model-benchmark
```

**Status:** vibestack does **not** include this binary. `/benchmark-models` will detect the missing binary and exit with a clear message.

**If you have your own:** drop it at the path above and `/benchmark-models` will use it.

---

## Why aren't these bundled?

vibestack is a curated skills pack. The browse daemon and the model-benchmark CLI are non-trivial standalone projects (a Chromium controller and a multi-provider LLM benchmark tool). Building and shipping them would expand the project scope well beyond "skills pack." The gh CLI, the aws CLI and the MCP inspector are a different case: other people's tools, with their own release cadence, install story and credential handling — vendoring any of them would mean shipping a stale copy, and in gh's case a second copy of a credential store the machine already has. The honest path in every case is to document the gap and let skills fail gracefully when the dependency is absent.

The affected skills are kept in the pack because (a) they're useful when the daemon **is** available, (b) they fall back when it isn't, and (c) deleting them would lose the integration scaffolding for anyone who supplies their own daemon.

---

## Audit history

- **2026-04-30** — Capability audit (per `/plan-devex-review` cross-model finding) confirmed the gap and added this document. Previously the affected skills told users to run `./setup` — a script that does not exist. Updated each skill's NEEDS_SETUP block to point here instead.
