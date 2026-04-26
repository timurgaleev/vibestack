# vibestack

A personal Claude Code skills pack — 53 specialist workflows as slash commands.

**Requirements:** Claude Code, Git, Bash

---

## Install (30 seconds)

```bash
git clone https://github.com/timurgaleev/vibestack ~/.claude/skills/vibestack
~/.claude/skills/vibestack/install
```

Start a new Claude Code session. Skills are immediately available.

## Uninstall

```bash
~/.claude/skills/vibestack/uninstall
```

## Update

```bash
cd ~/.claude/skills/vibestack && git pull && ./install
```

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
| `/code-audit` | Deep code audit — architecture, quality, security, performance. Audit only. |
| `/validate` | Run lint, typecheck, and tests. Fix all failures automatically. |
| `/commit` | Create a git commit with conventional format |
| `/commit-push` | Create a git commit and push to remote |
| `/pr-create` | Create a pull request with full diff analysis and test plan |
| `/pr-summary` | Analyze all PR changes and update the PR description |
| `/resolve-coderabbit` | Address CodeRabbit review comments, evaluating each technically |

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
| `/docs-sync` | Analyze code and docs, find gaps, update stale documentation |
| `/reroll-buddy` | Reset the Claude Code `/buddy` companion pet |

### Session & Context
| Command | What it does |
|---------|-------------|
| `/context-save` | Save working context (git state, decisions, remaining work) to resume later |
| `/context-restore` | Restore saved context and pick up exactly where you left off |
| `/context-init` | Initialize project context by reading docs, save to `./context.md` |
| `/context-load` | Load saved project context from `./context.md` |

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
