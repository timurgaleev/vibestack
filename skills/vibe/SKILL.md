---
name: vibe
description: |
  Router for the vibestack skills: name the task and it picks the right skill, also where there is no / picker.
allowed-tools:
  - Bash
  - Read
  - Skill
triggers:
  - which vibestack skill
  - what vibestack skills are there
  - list vibestack skills
  - vibestack help
  - vibe help
---

## When to invoke

Use when the task clearly wants a vibestack workflow but the right one is not
obvious, or when the host has no slash-command picker and the pack has to be
found by name. In Claude Code, Cursor and Kiro, skills are `/name`. In Codex
there is no `/` picker — reference a skill as `$name` inside an ordinary
message (`Use $office-hours to shape this idea`).

# /vibe — pick the right skill

The router is named `vibe`, not `vibestack`: the pack's own checkout is
sometimes parked at `~/.claude/skills/vibestack`, and a skill installing to that
path would collide with it — the installer's own integration test asserts that
checkout survives.

Route on intent. Process skills come first: brainstorm or plan before
implementing, investigate before fixing, review before shipping.

| When the task is… | Use |
|---|---|
| Shape a rough idea into a design doc | `office-hours` |
| Turn intent into a precise, executable spec | `spec` |
| Plan a feature, refactor, or architecture change | `plan-eng-review`, `autoplan` |
| Weigh product scope or the bigger problem | `plan-ceo-review` |
| Plan a UI change, or review a design before it is built | `plan-design-review` |
| Pressure-test the developer experience of a plan | `plan-devex-review` |
| Audit the live developer experience of a shipped product | `devex-review` |
| Debug an error, test failure, or odd behavior | `investigate` |
| Review a diff before merge | `review` |
| Rewrite a PR description from its actual changes | `pr-summary` |
| Get a second opinion from a different model | `codex` or `claude` — by host, see below |
| Audit security | `cso` |
| QA a running web app | `qa` (fixes), `qa-only` (report) |
| Drive a browser, scrape a page, pair a remote agent | `browse`, `scrape`, `open-browser`, `pair-agent` |
| Test logged-in pages with your real browser's cookies | `connect-chrome`, `setup-browser-cookies` |
| Turn a browse or scrape flow that worked into a skill | `skillify` |
| Read, transcribe or send Telegram messages as yourself | `telegram` |
| Review a shipped UI, or explore design directions | `design-review`, `design-shotgun`, `design-consultation` |
| Turn an approved mockup into production HTML/CSS | `design-html` |
| Render a Mermaid diagram to HTML and PNG | `diagram` |
| Render markdown or HTML to a polished PDF | `make-pdf` |
| Ship: tests, version, changelog, PR | `ship` |
| See which VERSION slots open PRs already claim | `landing-report` |
| Address PR review threads and failing CI | `address-pr-review` |
| Merge, deploy, and confirm production health | `land-and-deploy`, `canary` (`setup-deploy` configures it once) |
| Measure page performance against a baseline | `benchmark` |
| Update docs after shipping | `document-release`, `document-generate` |
| Strip machine-sounding prose | `unslop` |
| Check code-quality health or find refactors | `health`, `improve-arch` |
| Review AWS spend | `aws-cost` |
| Cap paid-inference spend | `ai-cost-guard` |
| Audit Bedrock guardrails, region and tenant isolation | `bedrock-guardrails` |
| Review a knowledge base or RAG pipeline | `kb-review` |
| Review an Amazon Connect, Lex or voice solution | `connect-review` |
| Evaluate an agent or prompt | `agent-eval` |
| Review an MCP server | `mcp-review` |
| Save or restore working context across sessions | `context-save`, `context-restore` |
| Review, search or prune what the pack has learned | `learn` |
| Run a retrospective from git history | `retro` |
| Tune which questions the skills ask you | `plan-tune` |
| Guard a risky session | `careful`, `freeze`, `guard` (and `unfreeze` to release) |
| Update the pack itself | `vibe-upgrade` |

Anything not listed here is in the full index — read it rather than guessing at
a skill name:

```bash
_found=""
for _d in "${CLAUDE_SKILL_DIR:-}" "$HOME/.agents/skills/vibe" "$HOME/.claude/skills/vibe" \
          "$HOME/.cursor/skills/vibe" "$HOME/.kiro/skills/vibe" \
          ".agents/skills/vibe" ".claude/skills/vibe" ".cursor/skills/vibe" ".kiro/skills/vibe"; do
  if [ -n "$_d" ] && [ -r "$_d/skills-index.md" ]; then
    cat "$_d/skills-index.md"; _found=1; break
  fi
done
if [ -z "$_found" ]; then
  for _r in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.cursor/skills" "$HOME/.kiro/skills"; do
    [ -d "$_r" ] && { echo "$_r:"; ls "$_r"; }
  done
fi
```

The index sits next to this file, so if none of those paths resolve, read
`skills-index.md` from the directory this `SKILL.md` was loaded from.

**Second opinion — route by host.** The outside voice has to be a different
model from the one already running:

```bash
if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SANDBOX:-}" ]; then echo "HOST: codex"
elif [ -n "${CLAUDECODE:-}" ]; then echo "HOST: claude"
else echo "HOST: other"; fi
```

`HOST: claude` → `codex`. `HOST: codex` → `claude` (`codex` refuses to run
nested under Codex, and would be the same model anyway). `HOST: other` (Cursor,
Kiro) → `codex`, unless the session's own model is GPT, then `claude`.

Rules when routing:

- **Invoke it, don't describe it.** Once a skill fits, hand off: invoke it
  through the Skill tool (Claude Code, Cursor, Kiro), or on Codex load that
  skill's `SKILL.md` and follow it (users invoke it there as `Use $<name>`). Do not answer with a list of
  options, and do not do the skill's work freehand when the skill exists.
- **Answer directly instead** when the request is a quick factual question
  (including "which skills are there?" — show the table), a small edit the user
  scoped themselves, or the user asked for a direct answer rather than a
  workflow.
- **Pick one.** Don't stack skills; each carries its own full workflow, and a
  skill's own instructions take precedence once invoked.
- **Only route to a skill that is installed.** Don't guess a name: if the table
  or the index has nothing that fits, or the skill is not present on this host,
  say so and proceed normally — these are workflows, not dependencies.
