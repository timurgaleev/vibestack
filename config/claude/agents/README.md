# Claude Code Agents

This directory holds the sub-agent definitions deployed to `~/.claude/agents/` by `install.sh`.

- **Total agents:** 33
- **Model:** all agents use `opus` (Claude Opus 4.8) for deepest reasoning
- **Tool scoping:** writers/reviewers get `Read, Grep, Glob`; builders also get `Edit, Write, Bash`

## Original agents

| Name | Purpose |
|------|---------|
| `bug-hunter` | Debugging specialist for errors and test failures |
| `build-doctor` | Lint, typecheck, and build runner with auto-fix |
| `code-shaper` | Behavior-preserving code refactoring |
| `docs-crafter` | README, API docs, and comment writing |
| `quality-guard` | Holistic code review (quality, security, maintainability) |
| `spec-writer` | Unit and integration test authoring |
| `system-designer` | Systems-level architecture for scalability |
| `task-planner` | Complex feature and refactor planning |

## Category A — Must-have

| Name | Purpose | Tools |
|------|---------|-------|
| `software-architect` | Feature-level architecture, ADRs, trade-off matrices | Read, Grep, Glob |
| `backend-architect` | Scalable APIs, database schemas, caching, cloud infra | Read, Grep, Glob |
| `devops-automator` | Terraform/CDK, CI/CD, container orchestration, observability | Read, Edit, Write, Bash, Grep, Glob |
| `sre` | SLOs, error budgets, observability, toil reduction | Read, Grep, Glob |
| `security-engineer` | Threat modeling, secure code review, vulnerability assessment | Read, Grep, Glob |
| `technical-writer` | READMEs, API references, tutorials, docs-as-code | Read, Grep, Glob |
| `ai-engineer` | ML/LLM features, RAG, MLOps, production AI integration | Read, Edit, Write, Bash, Grep, Glob |
| `incident-response-commander` | Severity frameworks, blameless post-mortems, on-call programs | Read, Grep, Glob |
| `developer-advocate` | DevRel content, talks, developer experience advocacy | Read, Grep, Glob |
| `mcp-builder` | Model Context Protocol server design and implementation | Read, Edit, Write, Bash, Grep, Glob |

## Category B — Regular use

| Name | Purpose | Tools |
|------|---------|-------|
| `code-reviewer` | Pre-merge diff review for correctness, security, fit | Read, Grep, Glob |
| `database-optimizer` | Query plans, indexing, schema tuning at scale | Read, Edit, Write, Bash, Grep, Glob |
| `minimal-change-engineer` | Surgical bug fixes that don't bleed into adjacent code | Read, Edit, Write, Bash, Grep, Glob |
| `git-workflow-master` | Branching strategies, rebases, history rescue | Read, Edit, Write, Bash, Grep, Glob |
| `linkedin-content-creator` | LinkedIn posts, thought leadership, technical narrative | Read, Grep, Glob |
| `content-creator` | Blog posts, newsletters, long-form technical writing | Read, Grep, Glob |
| `trend-researcher` | Market and tech trend scanning for product/content | Read, Grep, Glob |
| `reality-checker` | End-to-end validation that features actually work | Read, Edit, Write, Bash, Grep, Glob |
| `performance-benchmarker` | Latency, throughput, load-testing, regression detection | Read, Edit, Write, Bash, Grep, Glob |
| `visual-storyteller` | Talk decks, technical diagrams, visual explanations | Read, Grep, Glob |

## Category C — Situational

| Name | Purpose | Tools |
|------|---------|-------|
| `rapid-prototyper` | Spikes, MVPs, throwaway demos | Read, Edit, Write, Bash, Grep, Glob |
| `codebase-onboarding-engineer` | Architecture tours and onboarding docs for unfamiliar repos | Read, Grep, Glob |
| `seo-specialist` | Content optimization, keyword strategy, ranking | Read, Grep, Glob |
| `ai-citation-strategist` | Structuring content for inclusion in LLM answers | Read, Grep, Glob |
| `workflow-architect` | n8n/Make/Zapier and custom orchestration pipelines | Read, Edit, Write, Bash, Grep, Glob |

## Agents kept alongside near-duplicates

| Agent | Near-duplicate | Why both |
|-------|----------------|----------|
| `code-reviewer` | `quality-guard` | `code-reviewer` is PR-diff scoped; `quality-guard` is holistic codebase review. |
| `software-architect` | `system-designer` | `software-architect` is feature/domain-level; `system-designer` is systems/scalability-level. |
| `minimal-change-engineer` | `code-shaper` | `minimal-change-engineer` is surgical bug fixes; `code-shaper` is behavior-preserving refactor. |
| `technical-writer` | `docs-crafter` | `technical-writer` is long-form developer docs; `docs-crafter` is inline/code-adjacent docs. |

## Frontmatter convention

Every agent file starts with:

```yaml
---
name: <kebab-case-name>
description: <action-oriented sentence with "Use PROACTIVELY when ..." trigger>
tools: <comma-separated subset>
model: opus
---
```

Every agent body ends with a `## Output discipline` section that pins terseness, file-line citation, and "no invented file paths" rules.
