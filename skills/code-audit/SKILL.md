---
name: code-audit
description: Deep code audit — analyze entire codebase for issues, root causes, and improvements.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Task
---

## Preamble

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.vibestack/bin/vibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

# Code Audit

Deeply analyze the entire codebase to identify issues, root causes, and improvements.

## Philosophy

- **Find root causes, not symptoms** — ask "why?" five times
- **Think carefully** — avoid rushing to conclusions; read all the way through before deciding
- **Understand context** — trace the full system flow, not individual files in isolation
- **Distinguish real risks** — separate theoretical issues from those with actual impact

## Rules

- Read files completely before making judgments
- Trace call chains and data flows end-to-end
- Distinguish symptoms from root causes
- Prioritize findings by actual impact, not theoretical risk
- Do NOT suggest changes without understanding full context
- Do NOT flag style preferences as issues
- Do NOT recommend fixes for non-existent problems

## Exclude Patterns

**Important: Always skip these directories before scanning.**

| Category | Directories |
|----------|-------------|
| Dependencies | `node_modules/`, `vendor/`, `bower_components/`, `.pnp/` |
| Build outputs | `dist/`, `build/`, `out/`, `target/`, `.next/`, `.nuxt/`, `.vercel/` |
| Cache | `.cache/`, `.tmp/`, `tmp/`, `__pycache__/`, `.turbo/`, `.parcel-cache/` |
| Virtual envs | `.venv/`, `venv/`, `.env/`, `env/` |
| VCS | `.git/`, `.svn/`, `.hg/` |
| IDE | `.idea/`, `.vscode/`, `.vs/` |
| Test outputs | `coverage/`, `.nyc_output/`, `test-results/` |
| Generated | `*.min.js`, `*.bundle.js`, lock files |
| OS | `.DS_Store`, `Thumbs.db` |

## Process

### Phase 1: Reconnaissance

Understand the full project structure, tech stack, and architecture.

```bash
# Project type detection
ls -la package.json pyproject.toml go.mod Cargo.toml Makefile 2>/dev/null

# Directory structure overview
ls -la
ls -d */ 2>/dev/null
```

**Read key files:**
1. `README.md` — project purpose and setup
2. `CLAUDE.md` — project conventions (if exists)
3. Package manifest (`package.json`, `pyproject.toml`, `go.mod`, etc.)
4. Configuration files (`tsconfig.json`, `.eslintrc`, `vite.config.*`, etc.)

**Build a mental model:**
- What is the project? What problem does it solve?
- What is the tech stack?
- What are the entry points?
- What are the architectural boundaries?

### Phase 2: Deep Analysis — parallel execution

**Run 4 specialized agents in parallel using Team mode.**

#### Team mode (recommended)

If `TeamCreate` is available, use Team mode:

```
1. Create a "code-audit" team with TeamCreate
2. Create 4 audit tasks with TaskCreate
3. Spawn each agent with team_name="code-audit" using the Task tool
4. Wait for all agents to complete (via SendMessage notifications)
5. Clean up with TeamDelete
```

**Team mode spawn example:**
```
Task(
  subagent_type="Explore",
  team_name="code-audit",
  name="security-auditor",
  prompt="[Security Audit prompt]"
)
```

#### Fallback: direct Task tool

If `TeamCreate` is not available, spawn parallel agents directly with the Task tool.

---

Run the following 4 analyses concurrently:

#### Agent 1: Security Audit
```
Analyze the entire codebase for security issues:
1. Hardcoded secrets (API keys, passwords, tokens, connection strings)
2. Input validation gaps (user input, API parameters, file uploads)
3. Injection vulnerabilities (SQL, XSS, command injection, path traversal)
4. Authentication/authorization flaws
5. Sensitive data exposure (logs, error messages, responses)
6. Insecure dependencies (known CVEs)
7. CSRF/CORS misconfiguration
8. Cryptographic weaknesses

For each finding, trace the data flow from source to sink.
Report file paths, line numbers, and severity.
```

#### Agent 2: Architecture & Design Audit
```
Analyze the codebase architecture and design:
1. Dependency structure — circular dependencies, tight coupling
2. Module boundaries — are responsibilities clearly separated?
3. Abstraction levels — leaky abstractions, wrong abstractions, missing abstractions
4. Data flow — how data moves through the system, transformation points
5. Error propagation — how errors flow, where they get swallowed
6. State management — shared mutable state, race conditions
7. Configuration management — hardcoded values, environment handling
8. API design — consistency, versioning, contract clarity

For each finding, explain WHY it's a problem and what the systemic impact is.
Report file paths and line numbers.
```

#### Agent 3: Code Quality & Maintainability Audit
```
Analyze the codebase for quality and maintainability issues:
1. Dead code — unused functions, variables, imports, files
2. Code duplication — copy-pasted logic that should be unified
3. Complexity — functions >50 lines, files >800 lines, deep nesting >4 levels
4. Naming — unclear, misleading, or inconsistent naming
5. Type safety — use of any, missing types, type assertions
6. Error handling — empty catch blocks, swallowed errors, generic handlers
7. Mutation — mutable state where immutability is expected
8. Magic values — unexplained numbers, strings, boolean flags

For each finding, report file paths, line numbers, and specific code.
```

#### Agent 4: Testing & Reliability Audit
```
Analyze the testing strategy and reliability:
1. Test coverage — what is tested, what is NOT tested
2. Critical paths without tests — business logic, error handlers, edge cases
3. Test quality — do tests actually verify behavior or just existence?
4. Flaky test indicators — timing dependencies, shared state, order dependency
5. Missing integration tests — component interaction gaps
6. Error scenario coverage — are failure paths tested?
7. Mock accuracy — do mocks reflect real behavior?
8. Build/CI reliability — configuration issues, missing steps

Report specific untested functions/paths and their risk level.
```

#### Team teardown

If Team mode was used, clean up after all agents complete:
```
1. Send SendMessage(type="shutdown_request") to each agent
2. Confirm all shutdown_responses, then run TeamDelete
```

### Phase 3: Root Cause Analysis

After gathering findings from all agents, perform root cause analysis:

**For each significant finding, apply the 5 Whys:**

```
Finding: [Description]
├── Why 1: [Direct cause]
│   ├── Why 2: [Underlying cause]
│   │   ├── Why 3: [Systemic cause]
│   │   │   ├── Why 4: [Process/design cause]
│   │   │   │   └── Why 5: [Root cause]
│   │   │   │       └── ROOT CAUSE: [Fundamental issue]
```

**Look for patterns across findings:**
- Do multiple findings share a common root cause?
- Are there systemic issues (process, architecture, tooling)?
- What is the relationship between findings?

### Phase 4: Impact Assessment

Classify each finding:

| Severity | Impact | Examples |
|----------|--------|----------|
| **CRITICAL** | Immediate risk to production, data loss, security breach | SQL injection, exposed secrets, data corruption |
| **HIGH** | Significant reliability/security risk, likely to cause incidents | Missing auth checks, unhandled errors in critical paths, race conditions |
| **MEDIUM** | Degrades maintainability, increases tech debt, potential bugs | Code duplication, missing tests for core logic, tight coupling |
| **LOW** | Minor quality issues, future maintenance burden | Naming inconsistencies, minor dead code, style violations |

**Assess each finding:**
1. **Likelihood** — how likely is this to cause a real problem?
2. **Blast radius** — if it fails, what is affected?
3. **Reversibility** — how hard is it to fix after the fact?
4. **Urgency** — does this need immediate attention?

### Phase 5: Report

```markdown
# Code Audit Report

> Project: {project name}
> Date: {date}
> Scope: Full codebase analysis

## Executive Summary

[2-3 sentences: overall health assessment, key risks, recommended actions]

## Findings by Severity

### CRITICAL ({count})

#### 1. {Finding Title} — {file}:{line}
- **Issue**: [What is wrong]
- **Root cause**: [Root cause from 5 Whys analysis]
- **Impact**: [What happens if not fixed]
- **Recommendation**: [Specific fix recommendation]

### HIGH ({count})
...

### MEDIUM ({count})
...

### LOW ({count})
...

## Root Cause Patterns

[Group findings by common root causes]

### Pattern 1: {Root Cause Category}
- **Affected areas**: {list of affected areas}
- **Root cause**: {systemic explanation}
- **Improvement direction**: {strategic recommendation}

### Pattern 2: ...

## Positive Highlights

[What the project does well — balanced review]

- ✅ {Good practice 1}
- ✅ {Good practice 2}

## Recommended Action Plan

### Immediate (CRITICAL)
1. {Action item with specific file/line references}

### Short-term (HIGH)
1. {Action item}

### Medium-term (MEDIUM)
1. {Action item}

## Metrics Summary

| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| Security Issues | {n} | 0 | {status} |
| Test Coverage | {n}% | ≥80% | {status} |
| Files >800 lines | {n} | 0 | {status} |
| Functions >50 lines | {n} | 0 | {status} |
| Dead code files | {n} | 0 | {status} |
| Code duplication | {n} spots | minimal | {status} |
```

## Audit Dimensions Checklist

### Security
- [ ] No hardcoded secrets
- [ ] All inputs validated at boundaries
- [ ] No injection vulnerabilities
- [ ] Auth/authz properly implemented
- [ ] Sensitive data not exposed in logs/errors
- [ ] Dependencies free of known CVEs

### Architecture
- [ ] Clear module boundaries
- [ ] No circular dependencies
- [ ] Consistent data flow patterns
- [ ] Proper separation of concerns
- [ ] Configuration externalized

### Code Quality
- [ ] No dead code
- [ ] Minimal duplication
- [ ] Functions <50 lines
- [ ] Files <800 lines
- [ ] Nesting depth <4 levels
- [ ] Consistent naming

### Error Handling
- [ ] No swallowed errors
- [ ] Specific error types used
- [ ] Error messages informative
- [ ] Failure paths tested

### Testing
- [ ] Core logic tested
- [ ] Critical paths tested
- [ ] Edge cases covered
- [ ] Error scenarios tested
- [ ] Coverage ≥80%

### Type Safety
- [ ] No `any` types
- [ ] Proper null handling
- [ ] Return types explicit
- [ ] API contracts typed

## Anti-Patterns

- Do NOT treat every finding as critical — prioritize honestly
- Do NOT suggest fixes without understanding the codebase's constraints
- Do NOT flag intentional patterns as issues (e.g., framework conventions)
- Do NOT recommend massive refactoring without justifying ROI
- Do NOT ignore the project's stage — MVP code has different standards than production
- Do NOT confuse "different from my preference" with "wrong"
- Do NOT skip positive highlights — balanced reviews build trust

---

## Capture Learnings

If you discovered a non-obvious pattern, pitfall, or insight during this session, log it:

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"code-audit","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern`, `pitfall`, `preference`, `architecture`, `operational`.

**Only log genuine discoveries.**
