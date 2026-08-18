# External tools

vibestack ships 6 binaries (`vibe-config`, `vibe-slug`, `vibe-learnings-log`, `vibe-learnings-search`, `vibe-render-skill`, `vibe-skill-track`). A handful of skills depend on **external tools that vibestack does not bundle**. Those skills detect availability at runtime and degrade to text-only operation when the dependency is missing.

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
  copy there is pruned by name. Skills are invoked as `$name` or via `/skills`.
  Runtime hooks unverified — same status as Cursor/Kiro before their Track B pass.

Other Agent-Skills-compatible runtimes (Gemini CLI, Antigravity, OpenCode,
Windsurf) are not yet a `--target=` option. The SKILL.md files would work; the
only blocker is one row per map in the target registry in `./install`.

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

**What it is:** a persistent headless Chromium daemon that exposes a fast (~100ms) command interface for navigating, screenshotting, asserting, and interacting with web pages. Skills that depend on it expect a binary at:

```
~/.claude/skills/vibestack/browse/dist/browse
```

or, in repo-local mode, at:

```
<repo>/.claude/skills/vibestack/browse/dist/browse
```

**Status:** vibestack does **not** include the browse daemon source or binary. There is currently no public, vibestack-bundled implementation. The four affected skills will detect the missing binary and emit `BROWSE_NOT_AVAILABLE` so the agent can fall back to text-only checks (curl, basic HTTP) where possible.

**If you have your own browse daemon:** drop the binary at the path above (or build it from your own source under `<repo>/browse/dist/browse`) and the skills will pick it up.

**If you don't:** the affected skills will skip gracefully and tell you what they couldn't do. Other 42 skills work fully without the daemon.

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

vibestack is a curated personal Claude Code skills pack. The browse daemon and the model-benchmark CLI are non-trivial standalone projects (a Chromium controller and a multi-provider LLM benchmark tool). Building and shipping them would expand the project scope well beyond "skills pack." The honest path is to document the gap and let skills fail gracefully when the dependency is absent.

The 4 affected skills are kept in the pack because (a) they're useful when the daemon **is** available, (b) they fall back when it isn't, and (c) deleting them would lose the integration scaffolding for anyone who supplies their own daemon.

---

## Audit history

- **2026-04-30** — Capability audit (per `/plan-devex-review` cross-model finding) confirmed the gap and added this document. Previously the affected skills told users to run `./setup` — a script that does not exist. Updated each skill's NEEDS_SETUP block to point here instead.
