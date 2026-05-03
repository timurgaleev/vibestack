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
- [ ] **Brand audit returns zero hits**: `grep -rn "gstack\|GStack\|garrytan\|ycombinator\|gbrain\|GBrain" skills/ docs/ README.md` is empty.
- [ ] **Skill count consistency** — if I added/removed a skill, the count is updated in `README.md` line 3 and matches `ls skills/ | wc -l` and `docs/skills.md` headings.
- [ ] **CHANGELOG.md** entry added under `## Unreleased` (or a new version section).
- [ ] **For new skills**: SKILL.md has the standard 4-key frontmatter (`name`, `description`, `allowed-tools`, `triggers`), the directory name matches `name:` exactly, and the skill is documented in both `README.md` skills table and `docs/skills.md`.
- [ ] **For hook script changes**: tested manually with `echo '{"tool_input":{...}}' | bash skills/<name>/bin/check-*.sh` per `CLAUDE.md` testing pattern.

## Notes for reviewer

<!-- Anything specific to flag: edge cases, design tradeoffs, follow-ups, related issues. -->
