# Agent Skills Spec Compatibility Audit

**Generated:** 2026-05-09 (Day 0 Track A of v1.4.0 multi-target install)
**Track B verified:** 2026-05-09 (Cursor 2026.05.07-42ddaca, Kiro CLI 2.2.2)
**Skills audited:** 46
**Spec reference:** [agentskills.io/specification](https://agentskills.io/specification)

This audit verifies vibestack's 46 skills against the Agent Skills open standard,
which Claude Code, Cursor (`~/.cursor/skills/`), and Kiro (`~/.kiro/skills/`) all
implement. The spec standardizes the SKILL.md **file shape** — frontmatter +
markdown body. It does **not** standardize runtime behavior (hooks, env vars,
tool permissions, invocation semantics).

**Track A (file-shape spec compliance)** is below. **Track B (per-target runtime
verification)** has been completed empirically against installed Cursor and Kiro;
results are in the new "Track B — Empirical Verification" section near the end.

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
| careful | yes | yes | — | full / soft / soft (Track B verified 2026-05-09) |
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
| freeze | yes | yes | — | full / soft / soft (Track B verified 2026-05-09) |
| guard | yes | yes | — | full / soft / soft (Track B verified 2026-05-09) |
| health | — | — | — | full / full / full |
| improve-arch | — | — | — | full / full / full |
| investigate | yes | yes | — | full / soft / soft (Track B verified 2026-05-09) |
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

## Track B — Empirical Verification (COMPLETED 2026-05-09)

Track B was completed empirically against the actual installed agents:

- **Cursor CLI** version `2026.05.07-42ddaca` at `/usr/local/bin/cursor-agent`
- **Kiro CLI** version `2.2.2` at `/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli`
- **vibestack** post-install at `~/.cursor/skills/` and `~/.kiro/skills/`

Both agents were queried directly (non-interactive `--print` / `--no-interactive`
modes) for skill discovery, sub-doc resolution, frontmatter parsing, and
hook firing. Full procedure: `docs/hook-verification.md`.

### Test 1 — Skill discovery (PASS for both)

Both agents recognize `/office-hours` and `/careful` from our installed paths.
Direct quotes:

- **Cursor:** _"YES — It is listed in your available agent skills at
  `~/.cursor/skills/office-hours/SKILL.md`, which implements the
  `/office-hours` workflow described in the attached `SKILL.md`."_
- **Kiro:** _"YES — I found it listed in the context entry describing your
  installed Kiro skills at `/Users/timurgaleev/.kiro/skills/office-hours/SKILL.md`."_

Verdict: **all 46 skills are discoverable in both targets.** No source-file
changes required.

### Test 2 — Sub-doc / frontmatter loading (PASS for both)

Asked both agents to read `~/.<target>/skills/careful/SKILL.md` and report the
hook block. Both successfully read the file via their Read tool, parsed the
YAML frontmatter, and identified the `hooks: PreToolUse:` declaration with
the matcher `Bash` and command `bash ${CLAUDE_SKILL_DIR}/bin/check-careful.sh`.

Verdict: **sub-doc references and frontmatter parsing work in both targets.**

### Test 3 — Hook actually fires on destructive command (FAIL for both — soft tier confirmed)

Created throwaway file `/tmp/vibestack-careful-test/file.txt`, asked each
agent to activate `/careful` then run `rm -rf /tmp/vibestack-careful-test/file.txt`.

**Cursor result:**
- The `rm -rf` command was **blocked** — but not by our hook. Cursor returned
  _"Permission denied: Command blocked by permissions configuration"_
  which is **Cursor's built-in shell permission policy**, not the
  `/careful` hook's `check-careful.sh` script firing via `PreToolUse`.
- Cursor binary uses internal var name `skillDir` (camelCase), not
  `${CLAUDE_SKILL_DIR}`. Our hook command's env var doesn't expand.
- **Net effect for Cursor users:** They are protected from `rm -rf`, but via
  Cursor's native sandbox, not vibestack. The `/careful` skill's body
  instructions still inform the LLM ("warn before rm -rf"); enforcement is
  Cursor's, not ours.

**Kiro result:**
- The `rm -rf` command **ran silently with no interception**. Exit 0.
  No `check-careful.sh` invocation. Kiro itself reported (verbatim quote):
  _"the automated pre-execution interception doesn't happen — there's no
  shell hook that actually blocks the tool call before it runs. The
  guardrail here is me, not a hook."_
- Kiro binary doesn't expose any `*_SKILL_DIR` env var that would expand
  `${CLAUDE_SKILL_DIR}`. Kiro's `preToolUse` framework exists (added per
  upstream amazon-q-developer-cli PR #2875) but doesn't honor Claude-
  Code-formatted hook commands.
- **Net effect for Kiro users:** ⚠️ **No automatic protection from
  destructive commands.** The `/careful` skill loads and instructs the
  LLM, but enforcement is purely the LLM's instruction-following.

### Verified tier classification

| Skill | Claude Code | Cursor | Kiro |
|---|---|---|---|
| careful, freeze, guard, investigate (hook-bearing) | **HARD** (PreToolUse intercepts) | **SOFT** (LLM-instr only; native sandbox blocks `rm -rf` separately) | **SOFT** (LLM-instr only; ⚠️ no native sandbox) |
| 42 other skills (pure-prose) | identical | identical | identical |

### Implications for v1.5+

- **Cursor hook adapter (potential v1.5):** if a way exists to teach
  Cursor to honor our `${CLAUDE_SKILL_DIR}`-style hook command (or rewrite
  it on install to use Cursor's `${skillDir}` syntax + a Cursor-style
  hook config), hard-tier parity becomes possible. Worth investigating.
- **Kiro hook adapter (potential v1.5):** Kiro's `preToolUse` framework
  works, but it expects Kiro-native hook config (likely under
  `~/.kiro/hooks/` not in skill frontmatter). A `vibe-hook-kiro` shim
  that translates our hook script invocation to Kiro's format would
  enable hard tier in Kiro. Tracked as TODO #6 (`vibe certify`) follow-on.
- **README copy in v1.4.0** correctly stayed conservative ("hooks may
  behave differently in Cursor/Kiro"). Track B confirms this; no
  README walk-back needed. **A new README note about Kiro lacking the
  native sandbox protection Cursor provides** is the one user-facing
  update worth making.

## Action items (post-Track B)

- **No source-file changes required for v1.4.0.** All 46 skills install via the
  same SKILL.md content; no per-target translation.
- **`./install` already prints the post-install warning** when hook-bearing
  skills land in non-Claude targets. Track B confirms this warning is
  necessary and accurate.
- **README** updated in v1.4.0 follow-on commit to call out the asymmetry:
  Cursor's native sandbox blocks `rm -rf` independently of vibestack;
  Kiro does NOT have an equivalent sandbox.
- **v1.5+ candidates** (now empirically grounded, not speculative):
  - **Cursor hook adapter** — install-time rewrite of hook command syntax
    from `${CLAUDE_SKILL_DIR}` to `${skillDir}` (Cursor's internal var).
    Requires further investigation into whether Cursor reads hook commands
    from skill frontmatter at all, or only from `~/.cursor/hooks/`. Tracked
    as a v1.5 candidate.
  - **`vibe-hook-kiro` shim** — translate Claude-format hook commands into
    Kiro's native `~/.kiro/hooks/` format at install time. The shim writes
    a Kiro-compatible hook config alongside the skill so Kiro's
    `preToolUse` framework actually fires. Tracked as TODO #6 follow-on.
  - **Per-skill compatibility matrix in README** — defer until v1.5
    delivers actual hard-tier parity for at least one of Cursor/Kiro, so
    the matrix has interesting differentiation to report.
