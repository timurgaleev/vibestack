# tstackvibe

A personal Claude Code skills pack — 53 specialist workflows as slash commands.

**Requirements:** Claude Code, Git, Bash

---

## Install (30 seconds)

```bash
git clone https://github.com/timurgaleev/tstackvibe ~/.claude/skills/tstackvibe-repo
~/.claude/skills/tstackvibe-repo/install
```

Start a new Claude Code session. Skills are immediately available.

## Uninstall

```bash
~/.claude/skills/tstackvibe-repo/uninstall
```

## Update

```bash
cd ~/.claude/skills/tstackvibe-repo && git pull && ./install
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

### Code Quality & Shipping
| Command | What it does |
|---------|-------------|
| `/review` | Pre-landing PR code review — correctness, security, DB safety, tests |
| `/ship` | Full ship workflow — merge base, tests, review, version bump, PR |
| `/investigate` | Systematic debugging — Iron Law: no fix without confirmed root cause |
| `/cso` | Security audit — OWASP Top 10 + STRIDE threat model |

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
| `/guard` | Audit invariants and contracts for a critical file or module |
| `/plan-tune` | Tune skill question behavior — reduce confirmations, set defaults, terse mode |

### Tooling & Integrations
| Command | What it does |
|---------|-------------|
| `/codex` | Second-opinion AI reviewer via OpenAI Codex — code review (pass/fail gate), adversarial challenge, or consult |
| `/make-pdf` | Generate professional PDFs from markdown, code, or HTML — cover page, TOC, watermark support |
| `/setup-deploy` | Configure deployment settings (platform, URL, health check) for `/land-and-deploy` |

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
