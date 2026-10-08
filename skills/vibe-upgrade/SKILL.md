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
an auto-upgrade. Report what the block actually printed: on `RESTORED` warn
"Auto-upgrade failed — restored the previous version. Run `/vibe-upgrade`
manually to retry."; on `RESTORE_FAILED` say the previous version could **not**
be restored and relay the recovery line it printed. Never claim a restore the
block did not report.

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

Each installed skill's `bin` is a symlink back into the cloned repo
(`<checkout>/skills/<name>/bin`); resolve one to find the primary checkout. Fall
back to common clone paths. Then note whether it's a git checkout (normal) or a
plain directory.

```bash
REPO=""
for _l in "$HOME"/.claude/skills/*/bin "$HOME"/.cursor/skills/*/bin "$HOME"/.kiro/skills/*/bin "$HOME"/.agents/skills/*/bin; do
  [ -L "$_l" ] || continue
  _T="$(readlink "$_l")"; _C="${_T%/skills/*/bin}"
  [ "$_C" != "$_T" ] && [ -f "$_C/install" ] && [ -f "$_C/VERSION" ] && REPO="$_C" && break
done
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

### Step 3.5: Record how the pack was installed

The upgrade re-runs `./install` exactly as it was originally run — the same
runtimes, the same scope, config only where config was deployed. It never uses
`--yes`, which means "all four runtimes" and would widen a Claude-only install
into Cursor, Kiro and Codex. The choices are read from what the install left
behind: the `.vibestack-manifest` in each skills root, and the config manifests
under `~/.local/state/vibekit/`. Substitute `REPO` (Step 2) and `_ROOT` (Step
2.5). The result is a small replay script, printed so the user can see it.
The optional plugin flags (`--deliberation`, `--caveman`, `--ponytail`) leave no
manifest, so they are not replayed; plugins already installed stay in place. Tell
the user to re-run `./install --only=config` with those flags if they want them
refreshed too.

```bash
_VH="${VIBESTACK_HOME:-$HOME/.vibestack}"
REPLAY="$_VH/upgrade-replay.sh"
_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/vibekit"
_USER_T=""; _CFG_T=""; _PROJ_T=""
for t in claude cursor kiro codex; do
  case "$t" in
    claude) r="$HOME/.claude/skills"; rel=".claude/skills" ;;
    cursor) r="$HOME/.cursor/skills"; rel=".cursor/skills" ;;
    kiro)   r="$HOME/.kiro/skills";   rel=".kiro/skills" ;;
    codex)  r="$HOME/.agents/skills"; rel=".agents/skills" ;;
  esac
  if [ -f "$r/.vibestack-manifest" ] || [ -f "$r/vibe-upgrade/SKILL.md" ] \
     || { [ "$t" = codex ] && [ -f "${CODEX_HOME:-$HOME/.codex}/skills/vibe-upgrade/SKILL.md" ]; }; then
    _USER_T="$_USER_T,$t"
  fi
  [ -f "$_STATE/manifest_$t" ] && _CFG_T="$_CFG_T,$t"
  # A project-scope install in the current repo that links back into this checkout.
  if [ -n "${_ROOT:-}" ] && [ -f "$_ROOT/$rel/.vibestack-manifest" ] \
     && [ "$(cd "$_ROOT/$rel" && pwd -P)" != "$(cd "$r" 2>/dev/null && pwd -P)" ]; then
    for l in "$_ROOT/$rel"/*/bin; do
      [ -L "$l" ] || continue
      case "$(readlink "$l")" in "$REPO"/skills/*) _PROJ_T="$_PROJ_T,$t"; break ;; esac
    done
  fi
done
_USER_T="${_USER_T#,}"; _CFG_T="${_CFG_T#,}"; _PROJ_T="${_PROJ_T#,}"
if [ -z "$_USER_T$_PROJ_T$_CFG_T" ]; then
  echo "REPLAY_UNKNOWN — no install manifest found; cannot tell which runtimes to refresh"
  exit 1
fi
_RTK=""; command -v rtk >/dev/null 2>&1 || _RTK=" --no-rtk"
mkdir -p "$_VH" || { echo "REPLAY_UNWRITABLE $_VH"; exit 1; }
{
  echo '#!/usr/bin/env bash'
  echo '# Re-runs the original ./install choices from the checkout given as $1.'
  echo 'cd "$1" || exit 1'
  if [ -n "$_USER_T" ]; then echo "./install --only=skills --target=$_USER_T || exit 1"; fi
  if [ -n "$_PROJ_T" ]; then
    printf './install --only=skills --scope=project --project-root=%q --target=%s || exit 1\n' "$_ROOT" "$_PROJ_T"
  fi
  if [ -n "$_CFG_T" ]; then echo "./install --only=config --target=$_CFG_T$_RTK || exit 1"; fi
} > "$REPLAY" || { echo "REPLAY_UNWRITABLE $REPLAY"; exit 1; }
echo "REPLAY=$REPLAY"
sed -n '4,$p' "$REPLAY"
```

On `REPLAY_UNKNOWN`: nothing has changed yet. In an auto-upgrade, stop (see the
stop rule below). Interactively, ask the user which runtimes vibestack is
installed into and whether they used `--with-config`, then write `$REPLAY` with
those `./install --only=... --target=...` lines and continue. Project-scope
installs in other repos are not visible from here — mention that they can be
refreshed by running `./install --scope=project ...` in each one.

### Stop rule (applies to Steps 3.5 through 4.5)

Every block in Steps 3.5 through 4.5 prints exactly one outcome token. Only these
mean success: `REPLAY=` (Step 3.5), `INSTALL_OK`, `VENDORED_UPGRADE_OK`,
`SYNC_OK`, `VENDORED_REMOVED` (Step 4.5). Any other token — including
`REPLAY_UNKNOWN`, `REPLAY_UNWRITABLE`, `FETCH_FAILED`, `PULL_BLOCKED`,
`INSTALL_FAILED`, `RESTORED`, `RESTORE_FAILED`, `NOT_A_VIBESTACK_INSTALL`,
`STALE_BACKUP`, `MKTEMP_FAILED`, `CLONE_FAILED`, `SWAP_FAILED`, `SYNC_FAILED`,
`SYNC_SKIPPED` — or a block that printed no token, means **stop**:

- Do **not** run Step 4.75 (migrations), Step 5 (marker), or Step 6 (what's new),
  and never print the "upgraded!" banner.
- Report the token and every line the block printed (recorded SHA, backup path,
  recovery command) to the user verbatim.
- In the inline flow, then continue with the skill the user originally invoked,
  on the version that is actually installed.

Step 4.5 is the partial case: the primary already upgraded, so a `SYNC_FAILED`,
`SYNC_SKIPPED` or `SKIP` there does not stop Steps 4.75–6 — say the vendored copy
was not refreshed or removed.

### Step 4: Upgrade the primary

Use `REPO` and `INSTALL_TYPE` from Step 2 and `REPLAY` from Step 3.5.

**For a git checkout (`global-git`):** fast-forward pull, then replay the
install. Never force-push and never hard-reset — a blocked pull is reported, not
forced, and the checkout is often a working clone with edits in it. If the
install fails during an auto-upgrade, move back to the pre-pull commit with
`git reset --keep` (which refuses rather than discard uncommitted changes) and
replay the install of the known-good version. Interactively, stop with the
recorded commit instead and let the user decide.

```bash
cd "$REPO" || exit 1
_AUTO=""
[ "${VIBESTACK_AUTO_UPGRADE:-}" = "1" ] && _AUTO="true"
[ -z "$_AUTO" ] && _AUTO=$(~/.vibestack/bin/vibe-config get auto_upgrade 2>/dev/null || true)
PREV_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
BR="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
git fetch --quiet origin || { echo "FETCH_FAILED — could not fetch origin in $REPO; nothing changed"; exit 1; }
if ! git pull --quiet --ff-only origin "$BR"; then
  echo "PULL_BLOCKED — local changes or non-fast-forward. Stash/commit first, then re-run /vibe-upgrade. Not forcing."
  exit 1
fi
if bash "$REPLAY" "$REPO"; then
  echo "INSTALL_OK $(cat VERSION 2>/dev/null || echo unknown)"
  exit 0
fi
if { [ "$_AUTO" = "true" ] || [ "$_AUTO" = "1" ]; } && [ -n "$PREV_SHA" ]; then
  if ! git reset --quiet --keep "$PREV_SHA"; then
    echo "RESTORE_FAILED — could not move $REPO back to $PREV_SHA without touching local changes."
    echo "  Recover by hand: run git -C \"$REPO\" status, commit or stash the files it lists,"
    echo "  then: git -C \"$REPO\" reset --keep $PREV_SHA && bash \"$REPLAY\" \"$REPO\""
    exit 1
  fi
  if bash "$REPLAY" "$REPO"; then
    echo "RESTORED $PREV_SHA — the new version failed to install; the previous version is installed again"
  else
    echo "RESTORE_FAILED — checkout is back at $PREV_SHA, but re-installing it also failed."
    echo "  Recover by hand: bash \"$REPLAY\" \"$REPO\""
  fi
  exit 1
fi
echo "INSTALL_FAILED — the checkout is now at $(git rev-parse --short HEAD 2>/dev/null); the previous commit was $PREV_SHA."
echo "  To go back: git -C \"$REPO\" reset --keep $PREV_SHA && bash \"$REPLAY\" \"$REPO\""
exit 1
```

**For a plain vendored primary (`vendored`, no `.git`):** clone a fresh copy next
to it, swap it in with a backup, replay the install, and put the backup back on
failure. Each move is checked, and the live install is never deleted — on a
failure it is either still in place or still at `$REPO.bak`.

```bash
[ -f "$REPO/install" ] && [ -f "$REPO/VERSION" ] || { echo "NOT_A_VIBESTACK_INSTALL $REPO"; exit 1; }
if [ -e "$REPO.bak" ] || [ -L "$REPO.bak" ]; then
  echo "STALE_BACKUP — $REPO.bak is left over from an interrupted upgrade. Check which copy you want, move or delete $REPO.bak, then re-run /vibe-upgrade."
  exit 1
fi
TMP_DIR="$(mktemp -d "$(dirname "$REPO")/.vibestack-upgrade.XXXXXX")" && [ -d "$TMP_DIR" ] \
  || { echo "MKTEMP_FAILED — could not create a staging directory next to $REPO; nothing changed"; exit 1; }
if ! git clone --quiet --depth 1 https://github.com/timurgaleev/vibestack.git "$TMP_DIR/vibestack" \
   || [ ! -f "$TMP_DIR/vibestack/install" ]; then
  rm -rf "$TMP_DIR"; echo "CLONE_FAILED — nothing changed"; exit 1
fi
if ! mv "$REPO" "$REPO.bak"; then
  rm -rf "$TMP_DIR"; echo "SWAP_FAILED — could not move $REPO aside; nothing changed"; exit 1
fi
if [ -e "$REPO" ] || ! mv "$TMP_DIR/vibestack" "$REPO"; then
  if [ ! -e "$REPO" ] && mv "$REPO.bak" "$REPO"; then
    rm -rf "$TMP_DIR"; echo "SWAP_FAILED — could not move the new copy in; previous install is back at $REPO"
  else
    echo "SWAP_FAILED — RESTORE_FAILED: the previous install is kept at $REPO.bak and the new copy at $TMP_DIR. Move $REPO.bak back to $REPO by hand."
  fi
  exit 1
fi
if bash "$REPLAY" "$REPO"; then
  rm -rf "$REPO.bak" "$TMP_DIR"
  echo "VENDORED_UPGRADE_OK $(cat "$REPO/VERSION" 2>/dev/null || echo unknown)"
  exit 0
fi
# The new copy failed to install: park it, put the backup back, re-install it.
if mv "$REPO" "$TMP_DIR/failed" && mv "$REPO.bak" "$REPO"; then
  rm -rf "$TMP_DIR"
  if bash "$REPLAY" "$REPO"; then
    echo "RESTORED — the new version failed to install; the previous version is installed again"
  else
    echo "RESTORE_FAILED — the previous copy is back at $REPO, but re-installing it failed. Recover: bash \"$REPLAY\" \"$REPO\""
  fi
else
  echo "RESTORE_FAILED — the previous install is kept at $REPO.bak (the failed new copy is at $REPO or $TMP_DIR/failed). Move $REPO.bak back to $REPO by hand."
fi
exit 1
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
cd "$_ROOT" || { echo "SYNC_FAILED — cannot enter $_ROOT"; exit 1; }
_REL="${LOCAL_VIBESTACK#$_ROOT/}"
git rm -r --cached "$_REL" 2>/dev/null || true
if ! grep -qF "$_REL/" .gitignore 2>/dev/null; then
  echo "$_REL/" >> .gitignore
fi
rm -rf "$LOCAL_VIBESTACK" || { echo "SYNC_FAILED — could not remove $LOCAL_VIBESTACK"; exit 1; }
echo "VENDORED_REMOVED $LOCAL_VIBESTACK"
```
On `VENDORED_REMOVED` tell the user: "Removed vendored copy at `$LOCAL_VIBESTACK` (team mode active —
the global install is the source of truth). Commit the `.gitignore` change when
ready."

**If `LOCAL_VIBESTACK` is non-empty AND `TEAM_MODE` is NOT `true`:** refresh the
vendored copy's files from the freshly-upgraded primary (with a backup restore on
failure). The global install is already up to date, so this only re-stages the
committed copy — teammates run `./install` from it themselves. The new copy is
staged completely before the live one is moved, and every move is checked.

```bash
case "$LOCAL_VIBESTACK" in /?*) : ;; *) echo "SYNC_SKIPPED — no valid vendored copy path"; exit 1 ;; esac
[ -f "$LOCAL_VIBESTACK/install" ] && [ -f "$LOCAL_VIBESTACK/VERSION" ] \
  || { echo "SYNC_SKIPPED — $LOCAL_VIBESTACK is not a vibestack copy"; exit 1; }
if [ -e "$LOCAL_VIBESTACK.bak" ] || [ -L "$LOCAL_VIBESTACK.bak" ]; then
  echo "SYNC_SKIPPED — $LOCAL_VIBESTACK.bak is left over from an interrupted sync; move or delete it, then re-run /vibe-upgrade"
  exit 1
fi
_STAGE="$(mktemp -d "$(dirname "$LOCAL_VIBESTACK")/.vibestack-sync.XXXXXX")" && [ -d "$_STAGE" ] \
  || { echo "SYNC_FAILED — could not create a staging directory; vendored copy unchanged"; exit 1; }
if ! { mkdir "$_STAGE/copy" && cp -R "$REPO/." "$_STAGE/copy/" && rm -rf "$_STAGE/copy/.git"; }; then
  rm -rf "$_STAGE"; echo "SYNC_FAILED — could not stage the new copy; vendored copy unchanged"; exit 1
fi
if ! mv "$LOCAL_VIBESTACK" "$LOCAL_VIBESTACK.bak"; then
  rm -rf "$_STAGE"; echo "SYNC_FAILED — could not move the vendored copy aside; unchanged"; exit 1
fi
if [ ! -e "$LOCAL_VIBESTACK" ] && mv "$_STAGE/copy" "$LOCAL_VIBESTACK"; then
  rm -rf "$LOCAL_VIBESTACK.bak" "$_STAGE"
  echo "SYNC_OK"
elif [ ! -e "$LOCAL_VIBESTACK" ] && mv "$LOCAL_VIBESTACK.bak" "$LOCAL_VIBESTACK"; then
  rm -rf "$_STAGE"; echo "SYNC_FAILED — restored the previous version at $LOCAL_VIBESTACK"; exit 1
else
  echo "SYNC_FAILED — the previous vendored copy is kept at $LOCAL_VIBESTACK.bak; move it back by hand"; exit 1
fi
```
On `SYNC_OK` tell the user: "Also refreshed the vendored copy at
`$LOCAL_VIBESTACK` — commit it when you're ready." On `SYNC_FAILED` or
`SYNC_SKIPPED` relay the printed line and say the vendored copy was not
refreshed; run `/vibe-upgrade` manually to retry once it is resolved.

### Step 4.75: Run version migrations

Only after Step 4 printed `INSTALL_OK` or `VENDORED_UPGRADE_OK` (see the stop
rule), run any migration scripts for versions between the
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

Only after a successful Step 4. The marker drives the next session's what's-new
message, so writing it after a failed or rolled-back upgrade would announce a
version that is not installed.

```bash
mkdir -p ~/.vibestack
echo "$OLD_VERSION" > ~/.vibestack/just-upgraded-from
rm -f ~/.vibestack/.update-check-stamp ~/.vibestack/.update-check-failed
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
is available; no output means the primary is already current. A
`CHECK_FAILED <reason>` line means the update status is **unknown** — the remote
could not be read. Never report "already on the latest version" in that case.
Tell the user the check failed and why (the line names the remote and the
checkout), then use AskUserQuestion: "Try the upgrade anyway?" with options
["Yes, run the upgrade", "No, stop here"]. On yes, continue as in point 2 —
pulling an already-current checkout is harmless. On no, stop.

2. **If an update is available:** run Step 2 and Step 2.5 to locate the install,
   then follow Steps 3–6 (skip Step 1 — the invocation is the consent), obeying
   the stop rule.

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

**Never force-push, and never hard-reset.** A blocked pull is reported, not
overridden. The only reset is the scoped auto-upgrade rollback in Step 4 — a
`git reset --keep` to the commit you were just on, which refuses rather than
discard local changes. Never re-install with `--yes`; always replay the original
install from Step 3.5.
