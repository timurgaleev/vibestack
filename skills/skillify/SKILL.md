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

**Provenance guard (STOP if it fails).** /skillify only codifies a flow that
actually ran in this session. If there is no recent, working browse/scrape flow
to point at — the user is asking you to invent a skill from scratch — refuse:
"skillify codifies a flow that already worked; I don't see one in this session.
Run the browse/scrape steps first, confirm they work, then skillify them." Do not
fabricate steps.

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

**Name-collision check (STOP before writing).** A new skill must not silently
overwrite an existing one:

```bash
[ -e "$REPO/skills/<name>" ] && echo "NAME_TAKEN" || echo "NAME_FREE"
```

If `NAME_TAKEN`, use AskUserQuestion: "A skill named `<name>` already exists.
A) Pick a different name, B) Overwrite it (its current SKILL.md is replaced)."
Only proceed to write when the answer is a free name or an explicit overwrite.

Write `skills/<name>/SKILL.md` with: frontmatter (`name`, one-sentence
`description`, `allowed-tools`, `triggers`), a `## When to invoke` section, the
`{{include lib/snippets/browse-setup.md}}` directive, the captured `$B` steps with
their selectors, the extraction/return logic, and a closing
`{{include lib/snippets/capture-learnings.md}}`. Match the house style of an
existing skill (e.g. `skills/scrape/SKILL.md`). Keep brand-clean — no external
project names.

### 3. Validate, then install (staged — nothing lands until it's clean)

Validate the source BEFORE installing, so a half-broken skill never reaches the
live skills dir:

```bash
cd "$REPO"
bin/vibe-render-skill "skills/<name>/SKILL.md" /tmp/_skillify_check.md && echo "RENDER_OK" || echo "RENDER_FAIL"
# Run the repo's zero-external-brand audit (the grep in CLAUDE.md) against the
# new skill — it must return nothing. Report BRAND_HIT if it matches anything.
```

**Discard-on-failure.** If `RENDER_FAIL` or `BRAND_HIT`, do NOT install. Remove the
staged source and stop, reporting what failed:

```bash
# only when validation failed:
rm -rf "skills/<name>"
```

**Approval gate (STOP — do not install without it).** Installing writes into the
user's live skills dir. Use AskUserQuestion: "New skill `/<name>` validated
(render OK, brand clean). Install it into your skills dir now? A) Install,
B) Keep the source only — I'll `/ship` it myself." Only run `./install` on A.

```bash
./install --yes
```

Confirm install reports the new count. Then **functionally verify** the skill is
resolvable: `bin/vibe-render-skill` on the installed path succeeds and the
frontmatter `name` matches `<name>`.

### 4. Hand off

Tell the user the new `/<name>` is installed; a new agent session may be needed
if the host doesn't hot-reload. Suggest they bump the skill count in the README
and `docs/skills.md`, and `/ship` the change when ready.

{{include lib/snippets/capture-learnings.md}}
