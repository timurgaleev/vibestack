# vibestack

A personal Claude Code skills pack — 46 specialist workflows as slash commands.

**Requirements:** Claude Code, Git, Bash

---

## Install (30 seconds)

```bash
git clone https://github.com/timurgaleev/vibestack ~/.claude/skills/vibestack
~/.claude/skills/vibestack/install
```

Start a new Claude Code session. Skills are immediately available.

### What `./install` modifies on your machine

| Path | What lands there | Type |
|---|---|---|
| `~/.claude/skills/<each-skill>/` | One directory per skill (46 total). Each contains a symlink to its `SKILL.md` and any sub-docs/hook scripts in this repo. | symlinks |
| `~/.vibestack/bin/` | `vibe-config`, `vibe-slug`, `vibe-learnings-log`, `vibe-learnings-search` | copies |
| `~/.vibestack/projects/` | Per-project state (learnings, test plans, QA reports). Created empty. | directory |
| `~/.vibestack/analytics/` | Local-only analytics. Created empty. | directory |

`./install` is idempotent — re-running it after `git pull` updates the symlinks. To remove everything, see [Uninstall](#uninstall) below.

## Uninstall

```bash
~/.claude/skills/vibestack/uninstall
```

Removes all 46 skill directories from `~/.claude/skills/` and the `vibe-*` binaries from `~/.vibestack/bin/`. Asks before deleting `~/.vibestack/` (which contains your local learnings, analytics, and project state) — keeps it by default. The cloned repo at `~/.claude/skills/vibestack/` itself stays; delete it manually with `rm -rf ~/.claude/skills/vibestack` for a full removal. Pass `--delete-state` for a non-interactive full state wipe.

## Update

```bash
cd ~/.claude/skills/vibestack && git pull && ./install
```

---

## Try `/office-hours` in 30 seconds

After install, open a new Claude Code session and type `/office-hours`. You'll see something like:

```
LEARNINGS: none yet

Before we dig in — what's your goal with this?

  Building a startup (or thinking about it)
  Intrapreneurship — internal project at a company, need to ship fast
  Hackathon / demo — time-boxed, need to impress
  Open source / research — building for a community or exploring an idea
  Learning — teaching yourself to code, vibe coding, leveling up
```

Pick a mode and `/office-hours` walks you through targeted prompts — six forcing questions for startup mode, design-thinking flow for builder mode. The output is a saved design doc you can hand to `/plan-eng-review` next.

This is the shape of every skill in vibestack: opinionated, structured, no LLM-flavored mush. If `/office-hours` clicks, the other 45 will too.

---

## By workflow

| If you're... | Try |
|---|---|
| Brainstorming a new idea | `/office-hours` → `/plan-ceo-review` → `/plan-eng-review` |
| Debugging a bug | `/investigate` → `/freeze` (locks scope) → fix → `/learn` |
| Shipping a feature | `/tdd` → `/review` → `/ship` → `/pr-summary` |
| Hardening a codebase | `/improve-arch` → `/cso` → `/health` |
| Polishing a UI | `/design-consultation` → `/design-html` → `/design-review` |
| Capturing the week | `/retro` → `/learn` → `/document-release` |

Full reference of all 46 skills is below. See [`docs/skills.md`](docs/skills.md) for detailed descriptions.

---

## Skills

### Product & Planning
| Command | What it does |
|---------|-------------|
| `/office-hours` | Brainstorm ideas — startup mode (6 forcing questions) or builder mode |
| `/plan-ceo-review` | Challenge a plan's scope and ambition. 4 modes: expand / selective / hold / reduce |
| `/plan-eng-review` | Engineering plan review — architecture, data model, API, scalability, risk |
| `/plan-design-review` | UX plan review — flows, information architecture, interactions, accessibility |
| `/plan-devex-review` | Developer experience plan review — APIs, CLIs, SDKs. 3 modes: expand/polish/triage |
| `/autoplan` | Run all reviews automatically with auto-decisions. Surfaces only taste calls |
| `/plan-tune` | Tune skill question behavior — reduce confirmations, set defaults, terse mode |

### Code Quality & Shipping
| Command | What it does |
|---------|-------------|
| `/review` | Pre-landing PR code review — correctness, security, DB safety, tests |
| `/ship` | Full ship workflow — merge base, tests, review, version bump, PR |
| `/investigate` | Systematic debugging — Iron Law: no fix without confirmed root cause |
| `/cso` | Security audit — OWASP Top 10 + STRIDE threat model |
| `/pr-summary` | Analyze all PR changes and update the PR description |
| `/tdd` | Test-driven development — vertical-slice red-green-refactor; tests as behavior specs |
| `/improve-arch` | Find deepening opportunities — turn shallow modules into deep ones (Ousterhout) |

### QA & Testing
| Command | What it does |
|---------|-------------|
| `/qa` | QA test a feature and fix bugs found (iterative test-fix-verify) |
| `/qa-only` | QA audit report only — finds bugs, does not fix them |
| `/canary` | Canary deploy health check — compare error rates and latency |
| `/land-and-deploy` | Merge PR, monitor CI, verify production health after deploy |

### Design
| Command | What it does |
|---------|-------------|
| `/design-consultation` | Structured design direction conversation before building UI |
| `/design-review` | Review implemented UI for hierarchy, typography, spacing, AI slop |
| `/design-html` | Generate a realistic single-file HTML mockup (no Lorem ipsum) |
| `/design-shotgun` | Generate 3 distinct design variants side-by-side for comparison |

### Operations
| Command | What it does |
|---------|-------------|
| `/retro` | Weekly engineering retrospective — shipped, broke, blocked, action items |
| `/learn` | Capture and persist project learnings to prevent solving the same problem twice |
| `/document-release` | Write release notes and update CHANGELOG |
| `/devex-review` | Developer experience review — setup, CI, tooling, onboarding |
| `/health` | Code quality dashboard — type errors, lint, tests, coverage, security, composite score |
| `/benchmark` | Performance benchmarking — build size, test speed, regression detection |
| `/landing-report` | PR queue dashboard — CI status, merge-ready list, recent merges |
| `/reroll-buddy` | Reset the Claude Code `/buddy` companion pet |

### Session & Context
| Command | What it does |
|---------|-------------|
| `/context-save` | Save working context (git state, decisions, remaining work) to resume later |
| `/context-restore` | Restore saved context and pick up exactly where you left off |

### Safety & Scope Control
| Command | What it does |
|---------|-------------|
| `/careful` | Activate extra caution for risky operations (migrations, auth, production) |
| `/freeze` | Freeze scope — block new features and refactors until explicitly unfrozen |
| `/unfreeze` | Lift scope freeze |
| `/guard` | Full safety mode: `/careful` + `/freeze` combined |

### Tooling & Integrations
| Command | What it does |
|---------|-------------|
| `/codex` | Second-opinion AI reviewer via OpenAI Codex — review (pass/fail gate), challenge, or consult |
| `/claude` | Independent second opinion from a nested Claude instance — review, challenge, or consult |
| `/make-pdf` | Generate professional PDFs from markdown, code, or HTML — cover page, TOC, watermark support |
| `/setup-deploy` | Configure deployment settings (platform, URL, health check) for `/land-and-deploy` |
| `/benchmark-models` | Compare AI model outputs side-by-side across providers to find the best fit |
| `/browse` | Fast headless browser: navigate, interact, screenshot, diff, assert element states |
| `/open-browser` | Launch AI-controlled visible Chromium with real-time sidebar activity feed |
| `/pair-agent` | Pair a remote AI agent with your browser session over a secure tunnel |
| `/setup-browser-cookies` | Import cookies from your real browser into the headless browse session |
| `/setup-memory` | Set up secondbrain persistent memory as a Claude Code MCP tool |

---

## How skills work

Each skill is a `SKILL.md` file in `~/.claude/skills/<name>/`. Claude Code discovers them automatically and makes them available as `/name` commands. The install script creates the directories and symlinks — the source stays in this repo, so `git pull && ./install` is all you need to update.

## Adding your own skills

```bash
mkdir -p skills/my-skill
cat > skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: |
  What this skill does.
allowed-tools:
  - Bash
  - Read
triggers:
  - trigger phrase
---

## Skill instructions here
EOF

./install
```

Then use `/my-skill` in Claude Code.

---

## Data written locally

vibestack writes a small amount of state to your machine. **No data leaves your machine.** vibestack has no telemetry, no analytics endpoint, no remote logging.

| Path | What's written | When |
|---|---|---|
| `~/.vibestack/projects/<slug>/learnings.jsonl` | Learnings explicitly captured by `/learn` and the optional logging in skill bodies | When you run a skill that captures a learning |
| `~/.vibestack/analytics/skill-usage.jsonl` | One line per **explicit** `/skill-name` invocation: `{ts, skill, slug}`. Auto-invokes (where the LLM matches a skill by description without `/`) are **not** captured. | Only when the optional `vibe-skill-track` hook is wired in (see below). Off by default. |
| `~/.vibestack/hook.log` | Hook decision audit (which `/careful` warning fired, which `/freeze` block triggered, payload) | Only when `VIBESTACK_DEBUG=1` is set in your shell. Off by default. |
| `~/.vibestack/freeze-dir.txt` | The currently-frozen directory boundary | While `/freeze` is active |

**Disabling:**
- Skill invocation log: don't wire the `vibe-skill-track` hook, or set `VIBESTACK_TRACK=0` if it is wired.
- Hook decision audit: simply don't set `VIBESTACK_DEBUG=1`.
- Learnings: don't run `/learn`, or delete `~/.vibestack/projects/<slug>/learnings.jsonl`.

**Wiring `vibe-skill-track` (optional skill-usage analytics):**

Add this entry to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.vibestack/bin/vibe-skill-track"
          }
        ]
      }
    ]
  }
}
```

Then `~/.vibestack/analytics/skill-usage.jsonl` will record one line per explicit `/skill` invocation. Useful as input to `/devex-review` and `/retro` so you can see which skills you actually use.

> **Limitation (by design):** this hook captures explicit `/skill-name` invocations only. Skills that the LLM auto-invokes by description-match without you typing `/` are **not** logged. Claude Code does not currently expose a deterministic skill-start event.

---

## More

- [`ETHOS.md`](ETHOS.md) — five principles guiding skill design
- [`CHANGELOG.md`](CHANGELOG.md) — version history, including [removed skills](CHANGELOG.md#removed)
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to add a skill
- [`docs/skills.md`](docs/skills.md) — full skills reference with descriptions and triggers
- [`docs/external-tools.md`](docs/external-tools.md) — what vibestack does **not** bundle
- [`LICENSE`](LICENSE) — MIT

