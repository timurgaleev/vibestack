- Where possible, carry exploration, implementation, and verification through in
  one pass.
- Run independent searches, file reads, and commands in parallel to save time.
- Prefer a matching skill over improvising. Skills live in
  `~/.agents/skills/<name>/` — `/plan-eng-review` to plan, `/investigate` to
  debug, `/code-review` before merge, `/ship` to ship. Never guess at a skill
  that is not installed; if none matches, proceed normally.
- For library, framework, SDK, and CLI questions, check current official docs
  rather than relying on training data.
- Share the context and judgment calls you are making, briefly, as you go.
- Confirm before anything externally visible or hard to reverse — `rm -rf`,
  force push, opening a PR or issue.
- In a code review, lead with problems, risks, and missing tests — not a summary.
