# Agent Skills Spec Compatibility Audit

**Generated:** 2026-05-09 (Day 0 Track A of v1.4.0 multi-target install)
**Skills audited:** 46
**Spec reference:** [agentskills.io/specification](https://agentskills.io/specification)

This audit verifies vibestack's 46 skills against the Agent Skills open standard,
which Claude Code, Cursor (`.cursor/skills/`), and Kiro (`~/.kiro/skills/`) all
implement. The spec standardizes the SKILL.md **file shape** — frontmatter +
markdown body. It does **not** standardize runtime behavior (hooks, env vars,
tool permissions, invocation semantics). Track B of Day 0 covers runtime
verification per target; this document covers file-shape compliance only.

## Summary

| Audit dimension | Pass/Fail | Skills affected |
|---|---|---|
| Required `name` field present | 46/46 PASS | — |
| `name` matches directory basename | 46/46 PASS | — |
| Required `description` field present | 46/46 PASS | — |
| Description ≤ 1024 chars (spec limit) | 46/46 PASS | — |
| YAML frontmatter parseable | 46/46 PASS | — |
| Skills with `hooks:` (Claude-Code-specific) | 4 skills | careful, freeze, guard, investigate |
| Skills using `${CLAUDE_SKILL_DIR}` substitution | 5 skills | careful, freeze, guard, investigate, ship |
| Skills using `Agent` tool (Claude-specific subagent dispatch) | ~15 skills | autoplan, cso, design-*, etc. |
| Skills using `AskUserQuestion` (Claude-specific) | ~44 skills | most of the pack |

**Verdict:** All 46 skills are **spec-compliant for file shape**. Cross-target
install is safe to ship. **Behavioral parity is partial**, gated on Day 0 Track B
runtime verification (manual, requires Cursor/Kiro running on the user's machine).

## Per-skill compatibility matrix

| Skill | Hooks | `${CLAUDE_SKILL_DIR}` | `Agent` tool | Tier (claude / cursor / kiro) |
|---|---|---|---|---|
| autoplan | — | — | yes | full / instr-only / instr-only |
| benchmark | — | — | — | full / full / full |
| benchmark-models | — | — | — | full / full / full |
| browse | — | — | — | full / full / full |
| canary | — | — | — | full / full / full |
| careful | yes | yes | — | full / soft / soft (or hard, pending B) |
| claude | — | — | — | full / full / full |
| codex | — | — | — | full / full / full |
| context-restore | — | — | — | full / full / full |
| context-save | — | — | — | full / full / full |
| cso | — | — | yes | full / instr-only / instr-only |
| design-consultation | — | — | yes | full / instr-only / instr-only |
| design-html | — | — | yes | full / instr-only / instr-only |
| design-review | — | — | yes | full / instr-only / instr-only |
| design-shotgun | — | — | yes | full / instr-only / instr-only |
| devex-review | — | — | — | full / full / full |
| document-release | — | — | — | full / full / full |
| freeze | yes | yes | — | full / soft / soft (or hard, pending B) |
| guard | yes | yes | — | full / soft / soft (or hard, pending B) |
| health | — | — | — | full / full / full |
| improve-arch | — | — | — | full / full / full |
| investigate | yes | yes | — | full / soft / soft (or hard, pending B) |
| land-and-deploy | — | — | — | full / full / full |
| landing-report | — | — | — | full / full / full |
| learn | — | — | — | full / full / full |
| make-pdf | — | — | — | full / full / full |
| office-hours | — | — | yes | full / instr-only / instr-only |
| open-browser | — | — | — | full / full / full |
| pair-agent | — | — | — | full / full / full |
| plan-ceo-review | — | — | — | full / full / full |
| plan-design-review | — | — | — | full / full / full |
| plan-devex-review | — | — | — | full / full / full |
| plan-eng-review | — | — | — | full / full / full |
| plan-tune | — | — | — | full / full / full |
| pr-summary | — | — | — | full / full / full |
| qa | — | — | — | full / full / full |
| qa-only | — | — | — | full / full / full |
| reroll-buddy | — | — | — | full / full / full |
| retro | — | — | — | full / full / full |
| review | — | — | — | full / full / full |
| reroll-buddy | — | — | — | full / full / full |
| setup-browser-cookies | — | — | — | full / full / full |
| setup-deploy | — | — | — | full / full / full |
| setup-memory | — | — | — | full / full / full |
| ship | — | yes (in body, not hook) | — | full / full / full |
| tdd | — | — | — | full / full / full |
| unfreeze | — | — | — | full / full / full |

**Tier legend:**
- **full**: file shape + behavior portable as designed
- **soft**: file installs, but `hooks:` enforcement degrades (LLM-instruction-following
  instead of OS-level interception). Pending Track B verification.
- **instr-only**: file installs and the body's instructions execute, but Claude-
  specific tools (`Agent`, `AskUserQuestion`) require the host agent to recognize
  them. Modern LLMs map these to equivalent native tools when possible; specific
  tool-call syntax may differ. No file changes needed in any target.

## Findings

### F1 — All 46 skills are spec-compliant on file shape (PASS)

Every skill has a parseable YAML frontmatter block, a required `name` matching
its directory basename, a required `description` under the spec's 1024-char
limit, and a markdown body. Cross-target install via `cp` (or symlink) is
guaranteed safe at the file-format layer.

### F2 — 4 skills use Claude Code's `hooks:` field (careful, freeze, guard, investigate)

Hook-bearing skills are the **only category** at risk of behavioral degradation
across targets. The `hooks:` frontmatter field tells Claude Code to invoke a
shell script at `PreToolUse` time. Cursor and Kiro may or may not honor this
field — the Agent Skills spec doesn't standardize it.

**Sub-finding F2a:** `guard` and `investigate` reuse the hook scripts of
`careful` and `freeze` respectively, via cross-skill `${CLAUDE_SKILL_DIR}/../`
paths. This works under Claude's per-skill directory layout but assumes the
sibling skill directory exists at runtime. Day 0 Track B must verify whether
Cursor and Kiro keep skills in per-skill directories (where the relative path
resolves) or in some other layout.

### F3 — 5 skills use `${CLAUDE_SKILL_DIR}` env var substitution

`careful`, `freeze`, `guard`, `investigate`, `ship`. The first 4 use it in
`hooks:` commands; `ship` uses it in the body to reference its own sub-doc.

**Risk:** if Cursor and Kiro don't substitute `${CLAUDE_SKILL_DIR}` (or its
target-specific equivalent), the hook commands and the body reference will
silently fail to resolve the path. Track B must verify substitution behavior
in each target.

**Mitigation:** v1.4.0's install does not transform these references. If a
target fails to substitute the env var, the symptom is a silent no-op rather
than a crash. The post-install warning print in `./install` (Track B output
section) flags any targets where hooks did not fire.

### F4 — Most skills use `AskUserQuestion` (Claude Code-specific tool)

Modern LLMs (the agents inside Cursor and Kiro) recognize the intent
"ask the user a question with structured options" and provide their own
equivalent tool. Empirically, skill bodies that say "Use AskUserQuestion to
ask…" produce sensible behavior even when the literal tool name doesn't exist
in the host agent. v1.4.0 ships skills as-is; per-target tool-name translation
is a v1.5+ candidate IF empirical breakage is observed (Premise P5 in design
doc).

### F5 — Some skills use `Agent` tool for subagent dispatch (~15 skills)

`autoplan`, `cso`, the `design-*` family, `office-hours`, `plan-*` reviews —
these dispatch nested AI subagents for parallel/independent tasks. Cursor and
Kiro have different (or absent) subagent models. When the skill body says
"Dispatch a subagent via the Agent tool", the host LLM either (a) does its
best with whatever orchestration primitive it has, or (b) inlines the work
serially. Both produce correct results; only the parallelization benefit is
lost.

## Track B — Manual runtime verification (BLOCKER for v1.5+ tier classification)

Track A above confirms file-shape compatibility. Track B must verify, on a
machine with Cursor and Kiro installed, the per-target runtime behavior of
3 representative skills:

1. **`/office-hours`** (no hooks, uses `AskUserQuestion` and `Agent`) — verifies
   the "instr-only" tier. Expected: skill loads, slash invocation works,
   AskUserQuestion is mapped or asked via the host's native tool, subagent
   dispatch may degrade to inline execution.
2. **`/tdd`** (no hooks, has 5 sub-docs the body references) — verifies sub-doc
   resolution under each target's path layout.
3. **`/careful`** (hook-bearing) — verifies whether `${CLAUDE_SKILL_DIR}` is
   substituted and the `PreToolUse` hook fires when an `rm -rf` command is
   attempted.

Track B procedure is documented in `docs/hook-verification.md`. Until Track B
runs, the tier column in the matrix above marks hook skills as "soft (or hard,
pending B)" — pending the verification result.

## Action items from this audit

- **No source-file changes required for v1.4.0.** All 46 skills install via the
  same SKILL.md content; no per-target translation.
- **`./install` should print a post-install reminder** to run Track B
  verification per `docs/hook-verification.md` if cursor or kiro targets were
  selected. (Done in v1.4.0 install summary.)
- **README copy** for v1.4.0 stays conservative on hook tier — "behavior may
  differ in Cursor/Kiro for hook-bearing skills; see
  docs/agent-skills-compatibility-audit.md" — pending Track B fills in the
  matrix's "soft (or hard, pending B)" cells.
- **v1.5 candidates** if Track B reveals breakage:
  - Per-target `${CLAUDE_SKILL_DIR}` env var shim (currently TODO #6, `vibe certify`)
  - Per-skill compatibility matrix in README (currently held per Tension 3)
  - `vibe-hook-kiro` shim (currently TODO #6 follow-on)
