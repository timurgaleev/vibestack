<!--
Thanks for opening a PR. Run through the checklist below before requesting review.
-->

## What changed

<!-- One-paragraph summary. What does this PR do, and why? -->

## Type of change

- [ ] New skill
- [ ] Skill body or frontmatter edit
- [ ] Hook script change
- [ ] Install / uninstall script change
- [ ] Documentation only (README, ETHOS, CONTRIBUTING, docs/)
- [ ] Bug fix
- [ ] Refactor / cleanup

## Pre-flight checklist

- [ ] **`./install` runs without error** on a clean shell.
- [ ] **`./uninstall` followed by `./install` is idempotent** (no leftover state, no duplicate symlinks).
- [ ] **Naming audit clean** — `bin/vibe-brand-audit` and `bin/vibe-brand-audit --commits main..HEAD` both exit 0. CI runs these on every PR; a merged commit message cannot be corrected without rewriting published history.
- [ ] **Skill count consistency** — if I added/removed a skill, every count in `README.md` matches `ls skills/ | wc -l`, and `docs/skills.md` has a heading for each one.
- [ ] **CHANGELOG.md** entry added under `## Unreleased` (or a new version section).
- [ ] **For new skills**: SKILL.md has the standard 4-key frontmatter (`name`, `description`, `allowed-tools`, `triggers`), the directory name matches `name:` exactly, and the skill is documented in the `README.md` skills table, `docs/skills.md`, and the `/vibe` router.
- [ ] **For hook script changes**: tested manually with `echo '{"tool_input":{...}}' | bash skills/<name>/bin/check-*.sh` per `CLAUDE.md` testing pattern.

## Notes for reviewer

<!-- Anything specific to flag: edge cases, design tradeoffs, follow-ups, related issues. -->
