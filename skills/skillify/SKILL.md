---
name: skillify
description: |
  Turn a working browse or scrape flow into a reusable vibestack skill — codify the steps into a new SKILL.md, validate, and install it.
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
triggers:
  - skillify this
  - make this a skill
  - save this flow as a skill
  - codify this
---

## When to invoke

Use right after a browse/scrape flow worked and the user wants it reusable —
"skillify this", "make this a skill", "save this flow". It writes a new skill in
the local repo so future invocations just run `/the-new-name`.

# /skillify — Codify a flow into a skill

### 1. Capture the flow

From the session that just worked, pin down:

- **Intent + trigger phrases** — what the user will say to invoke it.
- **The exact steps** — the `$B` verbs / `chain` that worked, in order, with the
  selectors and the URL (or URL pattern / parameter) used.
- **The output shape** — the JSON or summary the flow produced.

If any of these is unclear, ask once with AskUserQuestion. Pick a short
kebab-case `name`.

### 2. Locate the repo and write the skill

Find the vibestack repo (the `vibe-*` binaries are symlinks into it):

```bash
REPO="$(cd "$(dirname "$(readlink "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-config" 2>/dev/null)")/.." 2>/dev/null && pwd || true)"
[ -f "$REPO/install" ] || { echo "REPO_NOT_FOUND"; }
```

If `REPO_NOT_FOUND`, ask the user where they cloned vibestack.

Write `skills/<name>/SKILL.md` with: frontmatter (`name`, one-sentence
`description`, `allowed-tools`, `triggers`), a `## When to invoke` section, the
`{{include lib/snippets/browse-setup.md}}` directive, the captured `$B` steps with
their selectors, the extraction/return logic, and a closing
`{{include lib/snippets/capture-learnings.md}}`. Match the house style of an
existing skill (e.g. `skills/scrape/SKILL.md`). Keep brand-clean — no external
project names.

### 3. Validate and install

```bash
cd "$REPO"
bin/vibe-render-skill "skills/<name>/SKILL.md" /tmp/_skillify_check.md && echo "RENDER_OK"
git grep -inE "gstack|garry|gbrain|ycombinator" -- "skills/<name>/" | head   # must be empty
./install --yes
```

Confirm `RENDER_OK`, zero brand hits, and that install reports the new count.

### 4. Hand off

Tell the user the new `/<name>` is installed; a new agent session may be needed
if the host doesn't hot-reload. Suggest they bump the skill count in the README
and `docs/skills.md`, and `/ship` the change when ready.

{{include lib/snippets/capture-learnings.md}}
