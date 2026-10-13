- **Plan before meaningful implementation.** Use Copilot's plan mode (Shift+Tab,
  or start with `--plan`) for new features, behavior changes, multi-place
  structural changes, refactors, and ambiguous requests. Outside plan mode, write
  the plan in the reply — the problem, the scope, how it will be verified, and
  the risks — and wait for agreement before editing.
- Prefer a matching skill over improvising. Skills live in
  `~/.copilot/skills/<name>/` (`$COPILOT_HOME/skills` when that is set) and are
  invoked by name: `/plan-eng-review` to plan, `/investigate` to debug,
  `/review` before merge, `/ship` to ship, `/vibe` when unsure. Never guess at a
  skill that is not installed; if none matches, proceed normally. Once a skill
  is invoked, its own instructions take precedence.
- Custom agents live in `~/.copilot/agents/<name>.agent.md` and are picked with
  `--agent <name>` or the agent command in a session. An agent does not see this
  file: put the criteria, the file scope, and the expected output in its prompt.
- Run independent searches, file reads, and commands in parallel.
- For library, framework, SDK, and CLI questions, check current official docs
  rather than relying on training data.
- Confirm before anything externally visible or hard to reverse — `rm -rf`,
  force push, opening a PR or issue. A pause from the pack's pre-tool hook on a
  destructive command is that confirmation, not an error to work around.
- In a code review, lead with problems, risks, and missing tests — not a summary.
