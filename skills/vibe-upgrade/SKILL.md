---
name: vibe-upgrade
description: |
  Update the installed vibestack pack to the latest release — detect the install (global git checkout or a project-local vendored copy), run the upgrade, run version migrations, and show what changed.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
triggers:
  - upgrade vibestack
  - update vibestack
  - update the skills
  - pull latest skills
  - get the latest vibestack
---

## When to invoke

Use when asked to "upgrade", "update vibestack", "get the latest skills", or
after `vibe-update-check` reports a newer version is available (a preamble that
sees `UPDATE:` in the update-check output runs the **Inline upgrade flow** below;
a direct `/vibe-upgrade` runs **Standalone usage**).

# /vibe-upgrade — Update vibestack to the latest release

Claude Code ships a built-in `/upgrade`, so this skill stays namespaced as
`/vibe-upgrade`. Binaries live in `~/.vibestack/bin/` (`vibe-config`,
`vibe-update-check`) and mutable state lives under `~/.vibestack/`.

## Inline upgrade flow

This section is referenced by skill preambles when they detect an available
update (`UPDATE:` line from `vibe-update-check`).

### Step 1: Ask the user (or auto-upgrade)

First, check whether auto-upgrade is enabled:

```bash
_AUTO=""
[ "${VIBESTACK_AUTO_UPGRADE:-}" = "1" ] && _AUTO="true"
[ -z "$_AUTO" ] && _AUTO=$(~/.vibestack/bin/vibe-config get auto_upgrade 2>/dev/null || true)
echo "AUTO_UPGRADE=$_AUTO"
```

**If `AUTO_UPGRADE=true` or `AUTO_UPGRADE=1`:** Skip the question. Log
"Auto-upgrading vibestack v{old} → v{new}..." and proceed directly to Step 2.
The upgrade blocks in Step 4 roll back automatically if `./install` fails during
an auto-upgrade — if that happens, warn the user: "Auto-upgrade failed — restored
the previous version. Run `/vibe-upgrade` manually to retry."

**Otherwise**, use AskUserQuestion:
- Question: "vibestack **v{new}** is available (you're on v{old}). Upgrade now?"
- Options: ["Yes, upgrade now", "Always keep me up to date", "Not now", "Never ask again"]

**If "Yes, upgrade now":** Proceed to Step 2.

**If "Always keep me up to date":**
```bash
~/.vibestack/bin/vibe-config set auto_upgrade true
```
Tell the user: "Auto-upgrade enabled. Future updates install automatically." Then
proceed to Step 2.

**If "Not now":** Write a snooze marker with escalating backoff (first snooze =
24h, second = 48h, third+ = 1 week), then continue with the skill the user
originally invoked. Do not mention the upgrade again this session.

```bash
_SNOOZE_FILE="$HOME/.vibestack/update-snoozed"
_REMOTE_VER="{new}"
_CUR_LEVEL=0
if [ -f "$_SNOOZE_FILE" ]; then
  _SNOOZED_VER=$(awk '{print $1}' "$_SNOOZE_FILE")
  if [ "$_SNOOZED_VER" = "$_REMOTE_VER" ]; then
    _CUR_LEVEL=$(awk '{print $2}' "$_SNOOZE_FILE")
    case "$_CUR_LEVEL" in *[!0-9]*) _CUR_LEVEL=0 ;; esac
  fi
fi
_NEW_LEVEL=$((_CUR_LEVEL + 1))
[ "$_NEW_LEVEL" -gt 3 ] && _NEW_LEVEL=3
mkdir -p "$HOME/.vibestack"
echo "$_REMOTE_VER $_NEW_LEVEL $(date +%s)" > "$_SNOOZE_FILE"
```
Note: substitute `{new}` (the remote version from the update-check result) for
`_REMOTE_VER`. Tell the user the snooze duration ("Next reminder in 24h", or 48h,
or 1 week, matching the level). Tip: "Enable automatic upgrades with
`~/.vibestack/bin/vibe-config set auto_upgrade true`."

**If "Never ask again":**
```bash
~/.vibestack/bin/vibe-config set update_check false
```
Tell the user: "Update checks disabled. Re-enable with
`~/.vibestack/bin/vibe-config set update_check true`." Continue with the current
skill.

### Step 2: Locate the install

The installed `vibe-*` binaries are symlinks back into the cloned repo; resolve
one to find the primary git checkout. Fall back to common clone paths. Then note
whether it's a git checkout (normal) or a plain directory.

```bash
REPO=""
_T="$(readlink "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-config" 2>/dev/null || true)"
[ -n "$_T" ] && REPO="$(cd "$(dirname "$_T")/.." 2>/dev/null && pwd || true)"
if [ -z "$REPO" ] || [ ! -f "$REPO/install" ]; then
  for d in "$HOME/.claude/skills/vibestack" "$HOME/data/vibestack" "$HOME/vibestack" "$HOME/code/vibestack"; do
    [ -f "$d/install" ] && [ -f "$d/VERSION" ] && REPO="$d" && break
  done
fi
if [ -z "$REPO" ] || [ ! -f "$REPO/install" ]; then
  echo "REPO_NOT_FOUND"
elif [ -d "$REPO/.git" ]; then
  echo "REPO=$REPO INSTALL_TYPE=global-git"
else
  echo "REPO=$REPO INSTALL_TYPE=vendored"
fi
```

If `REPO_NOT_FOUND`: check for a project-local vendored copy (Step 2.5). If there
is none either, ask the user where they cloned vibestack, then continue with that
path. The `REPO` and `INSTALL_TYPE` printed above are used in all later steps.

### Step 2.5: Detect a project-local vendored copy

A team can commit a vibestack checkout into a project so teammates get it without
a global install. Detect one distinct from the primary `REPO`, and read team mode:

```bash
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
LOCAL_VIBESTACK=""
if [ -n "$_ROOT" ]; then
  for cand in "$_ROOT/.vibestack" "$_ROOT/vendor/vibestack" "$_ROOT/tools/vibestack"; do
    if [ -f "$cand/install" ] && [ -f "$cand/VERSION" ]; then
      _RESOLVED_LOCAL=$(cd "$cand" && pwd -P)
      _RESOLVED_PRIMARY=$([ -n "$REPO" ] && cd "$REPO" 2>/dev/null && pwd -P || echo "")
      if [ "$_RESOLVED_LOCAL" != "$_RESOLVED_PRIMARY" ]; then
        LOCAL_VIBESTACK="$cand"; break
      fi
    fi
  done
fi
_TEAM_MODE=$(~/.vibestack/bin/vibe-config get team_mode 2>/dev/null || echo "false")
echo "LOCAL_VIBESTACK=$LOCAL_VIBESTACK"
echo "TEAM_MODE=$_TEAM_MODE"
```

If `REPO_NOT_FOUND` but `LOCAL_VIBESTACK` is non-empty, treat `LOCAL_VIBESTACK` as
`REPO` for the upgrade — the vendored copy is the only install here.

### Step 3: Save old version

```bash
OLD_VERSION=$(cat "$REPO/VERSION" 2>/dev/null || echo "unknown")
echo "OLD_VERSION=$OLD_VERSION"
```

Carry `OLD_VERSION` into the later steps (substitute the printed value).

### Step 4: Upgrade the primary

Use `REPO` and `INSTALL_TYPE` from Step 2.

**For a git checkout (`global-git`):** fast-forward pull, then re-install. Never
force-push and never hard-reset to override a blocked pull — a blocked pull is
reported, not forced. If `./install` fails during an auto-upgrade, roll back to
the pre-pull commit and re-install the known-good version.

```bash
cd "$REPO" || exit 1
_AUTO=""
[ "${VIBESTACK_AUTO_UPGRADE:-}" = "1" ] && _AUTO="true"
[ -z "$_AUTO" ] && _AUTO=$(~/.vibestack/bin/vibe-config get auto_upgrade 2>/dev/null || true)
PREV_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
BR="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
git fetch --quiet origin || { echo "FETCH_FAILED"; exit 0; }
if ! git pull --quiet --ff-only origin "$BR"; then
  echo "PULL_BLOCKED — local changes or non-fast-forward. Stash/commit first, then re-run /vibe-upgrade. Not forcing."
  exit 0
fi
if ./install --yes; then
  echo "INSTALL_OK $(cat VERSION 2>/dev/null || echo unknown)"
elif { [ "$_AUTO" = "true" ] || [ "$_AUTO" = "1" ]; } && [ -n "$PREV_SHA" ]; then
  git reset --hard "$PREV_SHA" >/dev/null 2>&1
  ./install --yes >/dev/null 2>&1 || true
  echo "AUTO_RESTORE_DONE"
else
  echo "INSTALL_FAILED"
fi
```

**For a plain vendored primary (`vendored`, no `.git`):** re-clone a fresh copy,
swap it in with a backup, re-install, and restore the backup on failure.

```bash
cd "$(dirname "$REPO")" || exit 1
TMP_DIR=$(mktemp -d)
git clone --depth 1 https://github.com/timurgaleev/vibestack.git "$TMP_DIR/vibestack" || { echo "CLONE_FAILED"; rm -rf "$TMP_DIR"; exit 0; }
mv "$REPO" "$REPO.bak"
mv "$TMP_DIR/vibestack" "$REPO"
if (cd "$REPO" && ./install --yes); then
  rm -rf "$REPO.bak" "$TMP_DIR"
  echo "VENDORED_UPGRADE_OK $(cat "$REPO/VERSION" 2>/dev/null || echo unknown)"
else
  rm -rf "$REPO"; mv "$REPO.bak" "$REPO"; rm -rf "$TMP_DIR"
  echo "VENDORED_UPGRADE_FAILED — restored previous version"
fi
```

### Step 4.5: Sync a project-local vendored copy

Only when Step 2.5 found `LOCAL_VIBESTACK` separate from the freshly-upgraded
`REPO`. Behavior depends on `TEAM_MODE`.

**If `LOCAL_VIBESTACK` is non-empty AND `TEAM_MODE` is `true`:** remove the
vendored copy — team mode uses the global install as the single source of truth.

```bash
# Guard: refuse to run without a concrete vendored-copy path (never rm an empty
# or root path). Both must be set and LOCAL_VIBESTACK must live under _ROOT.
case "$LOCAL_VIBESTACK" in "$_ROOT"/?*) : ;; *) echo "SKIP — no valid vendored copy under repo root"; exit 0 ;; esac
cd "$_ROOT" || exit 1
_REL="${LOCAL_VIBESTACK#$_ROOT/}"
git rm -r --cached "$_REL" 2>/dev/null || true
if ! grep -qF "$_REL/" .gitignore 2>/dev/null; then
  echo "$_REL/" >> .gitignore
fi
rm -rf "$LOCAL_VIBESTACK"
```
Tell the user: "Removed vendored copy at `$LOCAL_VIBESTACK` (team mode active —
the global install is the source of truth). Commit the `.gitignore` change when
ready."

**If `LOCAL_VIBESTACK` is non-empty AND `TEAM_MODE` is NOT `true`:** refresh the
vendored copy's files from the freshly-upgraded primary (with a backup restore on
failure). The global install is already up to date, so this only re-stages the
committed copy — teammates run `./install` from it themselves.

```bash
mv "$LOCAL_VIBESTACK" "$LOCAL_VIBESTACK.bak"
if cp -Rf "$REPO/." "$LOCAL_VIBESTACK" 2>/dev/null; then
  rm -rf "$LOCAL_VIBESTACK/.git"
  rm -rf "$LOCAL_VIBESTACK.bak"
  echo "SYNC_OK"
else
  rm -rf "$LOCAL_VIBESTACK"; mv "$LOCAL_VIBESTACK.bak" "$LOCAL_VIBESTACK"
  echo "SYNC_FAILED — restored previous version at $LOCAL_VIBESTACK"
fi
```
On `SYNC_OK` tell the user: "Also refreshed the vendored copy at
`$LOCAL_VIBESTACK` — commit it when you're ready." On `SYNC_FAILED` tell them:
"Sync failed — restored the previous vendored copy. Run `/vibe-upgrade` manually
to retry."

### Step 4.75: Run version migrations

After `./install` succeeds, run any migration scripts for versions between the
old and new version. Migrations handle state fixes `./install` alone can't cover
(stale config, orphaned files, directory-structure changes). Substitute
`OLD_VERSION` and `REPO` from earlier steps.

```bash
MIGRATIONS_DIR="$REPO/skills/vibe-upgrade/migrations"
if [ -d "$MIGRATIONS_DIR" ]; then
  for migration in $(find "$MIGRATIONS_DIR" -maxdepth 1 -name 'v*.sh' -type f 2>/dev/null | sort -V); do
    m_ver="$(basename "$migration" .sh | sed 's/^v//')"
    if [ "$OLD_VERSION" != "unknown" ] && [ "$(printf '%s\n%s' "$OLD_VERSION" "$m_ver" | sort -V | head -1)" = "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$m_ver" ]; then
      echo "Running migration $m_ver..."
      bash "$migration" || echo "  Warning: migration $m_ver had errors (non-fatal)"
    fi
  done
fi
```

Migrations are idempotent bash scripts in `skills/vibe-upgrade/migrations/`, each
named `v{VERSION}.sh`, run only when upgrading from an older version. See
`CLAUDE.md` for how to add one.

### Step 5: Write marker + clear cache

```bash
mkdir -p ~/.vibestack
echo "$OLD_VERSION" > ~/.vibestack/just-upgraded-from
rm -f ~/.vibestack/.update-check-stamp
rm -f ~/.vibestack/update-snoozed
```

### Step 6: Show what's new

Read `$REPO/CHANGELOG.md`. Find every version entry between the old and new
version and summarize as 5–7 bullets grouped by theme. Focus on user-facing
changes; skip internal refactors unless significant.

```
vibestack v{new} — upgraded from v{old}!

What's new:
- [bullet 1]
- [bullet 2]
- ...

Happy shipping!
```

Note that a new agent session may be needed if the host doesn't hot-reload skills.

### Step 7: Continue

After showing what's new, continue with whatever skill the user originally
invoked. The upgrade is done — no further action needed.

---

## Standalone usage

When invoked directly as `/vibe-upgrade` (not from a preamble), the user has
already opted in — skip the Step 1 question and go straight to the upgrade.

1. Force a fresh update check (bypasses the once/day throttle, snooze, and the
   `update_check` gate):
```bash
~/.vibestack/bin/vibe-update-check --force 2>/dev/null || true
```
An `UPDATE: vibestack <new> is available (you have <old>)` line means an upgrade
is available; no output means the primary is already current.

2. **If an update is available:** run Step 2 and Step 2.5 to locate the install,
   then follow Steps 3–6 (skip Step 1 — the invocation is the consent).

3. **If no update** (primary is current): run Step 2 and Step 2.5 to check for a
   stale project-local vendored copy.

   - **`LOCAL_VIBESTACK` empty** (no vendored copy): tell the user "You're already
     on the latest version (v{version})."
   - **`LOCAL_VIBESTACK` non-empty AND `TEAM_MODE` is `true`:** remove it with the
     team-mode removal block in Step 4.5. Tell the user: "Global v{version} is up
     to date. Removed the stale vendored copy (team mode active). Commit the
     `.gitignore` change when ready."
   - **`LOCAL_VIBESTACK` non-empty AND `TEAM_MODE` is NOT `true`:** compare
     versions:
     ```bash
     PRIMARY_VER=$(cat "$REPO/VERSION" 2>/dev/null || echo "unknown")
     LOCAL_VER=$(cat "$LOCAL_VIBESTACK/VERSION" 2>/dev/null || echo "unknown")
     echo "PRIMARY=$PRIMARY_VER LOCAL=$LOCAL_VER"
     ```
     - **Versions differ:** run the non-team sync block in Step 4.5. Tell the user:
       "Global v{PRIMARY_VER} is up to date. Refreshed the local vendored copy from
       v{LOCAL_VER} → v{PRIMARY_VER}. Commit it when you're ready."
     - **Versions match:** tell the user "You're on the latest version
       (v{PRIMARY_VER}). Global and vendored copy are both up to date."

**Never force-push, and never hard-reset to override a blocked pull.** A blocked
pull is reported, not overridden. The only reset is the scoped auto-upgrade
rollback in Step 4, which restores the commit you were just on.
