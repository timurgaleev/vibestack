# Skill Routing

These skills ship with this configuration — slash commands that carry a full
workflow. `./install` puts both halves on the machine, so if these rules are
loaded the skills are installed too. When a task matches one, prefer the skill
over improvising: invoke it before starting the work.

**Availability:** installing the configuration without the skills is possible
(`./install --only=config`), so a missing skill is not an error — proceed
normally if one is not there.

**Ordering:** Process skills come first. Brainstorm or plan before implementing;
investigate before fixing. Then run the implementation and review skills.

## Task → skill

| When the task is… | Use |
|-------------------|-----|
| Shape a rough idea, or turn intent into a precise spec | `/office-hours`, `/spec` |
| Plan a feature, refactor, or architecture change | `/plan-eng-review`, `/autoplan` |
| Weigh product scope, design, or developer experience of a plan | `/plan-ceo-review`, `/plan-design-review`, `/plan-devex-review` |
| Tune which questions the skills ask you | `/plan-tune` |
| Debug an error, test failure, or odd behavior | `/investigate` |
| Check code-quality health or find refactors | `/health`, `/improve-arch` |
| Review a diff before merge | `/review` |
| Second opinion from a different model | `/codex` (in Claude Code), `/claude` (in Codex) |
| Address PR review threads and failing CI | `/address-pr-review` |
| Audit security | `/cso` |
| QA a running web app | `/qa` (fixes), `/qa-only` (report) |
| Measure page performance | `/benchmark` |
| Drive a browser, scrape a page, pair a remote agent | `/browse`, `/scrape`, `/open-browser`, `/pair-agent` |
| Use logged-in browser cookies | `/connect-chrome`, `/setup-browser-cookies` |
| Turn a browse or scrape flow into a skill | `/skillify` |
| Review or explore a design | `/design-review`, `/design-shotgun`, `/design-consultation`, `/design-html` |
| Audit the live developer experience | `/devex-review` |
| Ship: tests, version, changelog, PR | `/ship`, `/pr-summary`, `/landing-report` |
| Merge, deploy, and confirm production health | `/land-and-deploy`, `/setup-deploy`, `/canary` |
| Update docs after shipping | `/document-release`, `/document-generate` |
| Render a diagram or a PDF; strip machine-sounding prose | `/diagram`, `/make-pdf`, `/unslop` |
| Review AWS spend, Bedrock guardrails, or a Connect solution | `/aws-cost`, `/bedrock-guardrails`, `/connect-review` |
| Review AI cost caps, a RAG pipeline, an agent eval, an MCP server | `/ai-cost-guard`, `/kb-review`, `/agent-eval`, `/mcp-review` |
| Save or restore context; record learnings; run a retro | `/context-save`, `/context-restore`, `/learn`, `/retro` |
| Read or send Telegram messages as yourself | `/telegram` |
| Guard a risky session | `/careful`, `/freeze`, `/guard`, `/unfreeze` |
| Update the pack itself | `/vibe-upgrade` |
| Not sure which fits | `/vibe` |

Use `/vibe` when unsure — it routes to the right skill or says none fits.

## Notes

- The slash command names above are the canonical triggers. The user may also
  describe the intent in their own words ("ship this", "review the diff") —
  route to the same skill.
- Don't stack skills needlessly. Pick the one that fits; let it run its workflow.
- A skill's own instructions take precedence once invoked.

## Outside the pack

These are not vibestack skills; each line names where it comes from.

| When the task is… | Use |
|-------------------|-----|
| Review a diff for correctness bugs (Claude Code built-in) | `/code-review` |
| Tidy code for reuse/simplicity, no bug hunt (Claude Code built-in) | `/simplify` |

Use the built-ins when they are installed; the pack's own `review` stays the
pre-merge gate.

### Second opinion from another model

The [deliberation](https://github.com/antonbabenko/deliberation) plugin delegates
a question to GPT, Gemini, Grok or an OpenRouter model. It is optional
(`./install -D`); where it is absent, carry on without it.

| When the task is… | Use |
|-------------------|-----|
| Put one question to several models at once (plugin) | `/deliberation:ask-all` |
| Settle a contested design decision (plugin) | `/deliberation:consensus` |
| Ask one named model (plugin) | `/deliberation:ask-gpt`, `:ask-gemini`, `:ask-grok`, `:ask-openrouter` |

- Use the namespaced form. The plugin's short aliases (`/ask-all`) exist only
  if its setup installed them.
- **Never delegate the same question twice.** Most vibestack review skills
  (review, ship, plan-eng-review, plan-ceo-review, spec, …) already run their
  own outside voice through Codex. When one of them is running, do not add a
  deliberation call on top.
- Only Gemini can edit files; GPT, Grok and OpenRouter advise only.
