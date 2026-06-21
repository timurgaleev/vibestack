---
name: vibe-upgrade
description: |
  Update the installed vibestack pack to the latest release — pull the repo, re-run install, and show what changed.
allowed-tools:
  - Bash
  - Read
triggers:
  - upgrade vibestack
  - update vibestack
  - update the skills
  - pull latest skills
  - get the latest vibestack
---

## When to invoke

Use when asked to "upgrade", "update vibestack", "get the latest skills", or
after `vibe-update-check` reports a newer version is available.

# /vibe-upgrade — Update vibestack to the latest release

### 1. Locate the vibestack repo

The installed `bin/vibe-*` are symlinks back into the cloned repo; resolve one to
find it. Fall back to common clone paths.

```bash
REPO=""
_T="$(readlink "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-config" 2>/dev/null || true)"
[ -n "$_T" ] && REPO="$(cd "$(dirname "$_T")/.." 2>/dev/null && pwd || true)"
if [ -z "$REPO" ] || [ ! -f "$REPO/install" ]; then
  for d in "$HOME/.claude/skills/vibestack" "$HOME/data/vibestack" "$HOME/vibestack" "$HOME/code/vibestack"; do
    [ -f "$d/install" ] && [ -f "$d/VERSION" ] && REPO="$d" && break
  done
fi
[ -n "$REPO" ] && echo "REPO: $REPO" || echo "REPO_NOT_FOUND"
```

If `REPO_NOT_FOUND`: ask the user where they cloned vibestack, then continue with
that path.

### 2. Pull and re-install

```bash
cd "$REPO"
BEFORE="$(cat VERSION 2>/dev/null)"
BR="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
git fetch --quiet origin || { echo "FETCH_FAILED"; exit 0; }
if ! git pull --quiet --ff-only origin "$BR"; then
  echo "PULL_BLOCKED — local changes or non-fast-forward. Stash/commit first, then re-run /vibe-upgrade. Not forcing."
  exit 0
fi
AFTER="$(cat VERSION 2>/dev/null)"
./install --yes
echo "UPGRADED: $BEFORE -> $AFTER"
```

### 3. Report what changed

- If `BEFORE` == `AFTER`: tell the user they were already on the latest.
- Otherwise read `CHANGELOG.md` and summarize the entries between the two
  versions (newest first) in plain language — what they can now do.
- Note that a new agent session may be needed if the host doesn't hot-reload
  skills.

**Never force-push or hard-reset.** A blocked pull is reported, not overridden.
