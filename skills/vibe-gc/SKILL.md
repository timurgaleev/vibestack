---
name: vibe-gc
description: |
  Audit runtime roots for unused skills, orphan hooks, shadowed permissions and stale caches; soft-delete with undo.
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
triggers:
  - vibe gc
  - clean up skills
  - garbage collect config
  - prune unused skills
---

## When to invoke

Use when the owner asks to clean up, slim down or audit what is installed
around the agent: too many skills, noisy hooks, a long permission list, a
bloated `~/.claude`, or a periodic (roughly monthly) configuration review. It
is not for cleaning project source code, chat history or the pack's own
skills — `./install` already prunes skills the pack withdrew.

The skill is **audit-only by default**. Nothing moves until the owner confirms
that one item, and every move is a soft delete with a logged undo.

{{include lib/snippets/session-host.md}}

## Step 1: Scan

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-gc" scan --days 30
```

Each row is `id  channel  path  signal  size_kb  mtime  confidence`, ranked
high → low, then by size, at most 20 rows. A shorter batch is the point: this
runs periodically, not exhaustively. Show the rows as a numbered table. When
the scan prints nothing, say the configuration is clean and stop.

What the channels mean:

- **skills** — directories in `~/.claude/skills`, `~/.agents/skills`,
  `~/.cursor/skills`, `~/.kiro/skills` or `~/.copilot/skills` (`$COPILOT_HOME/skills`
  when set) that the root's `.vibestack-manifest` does not claim. A missing or empty `SKILL.md` is high confidence; a name that
  repeats another root's skill is low. `usage: unmeasured` means no usage data
  exists for that root — it never makes an item more disposable.
- **hooks** — scripts under `~/.claude/hooks/` that nothing in the user
  `settings.json` / `settings.local.json` and no other hook script references.
  A project's own `.claude/settings.json` is not read, so confirm before
  trashing a hook a project may call.
- **permissions** — duplicate `permissions.allow` entries and `Bash(...)`
  entries already covered by `Bash(*)`. The scan only reports them.
- **mcp** — configured servers. The bin cannot see whether a server is live.
- **caches** — `file-history`, `shell-snapshots` and the `skills.old` /
  `skills.staging.*` entries an interrupted install leaves beside a skills root,
  older than `--days`.

## Step 2: Automation status

Build one table for the MCP servers and hooks the scan listed:

| Item | Configured | Authenticated | Recently verified | Stale or broken | Missing | Evidence |
|------|------------|---------------|-------------------|-----------------|---------|----------|

Fill the evidence column only from what this session observed. A server that
failed to connect in this session is "stale or broken (this session)"; a server
whose tools answered is "recently verified". A reference in a skill or a config
entry is not proof that anything is live, and a failed connection is not proof
that it is disposable — a server can be down for a day.

This skill never changes MCP, n8n, cron or launchd state. For an item that
looks broken, name the owner's action (re-authenticate, restart the server,
remove the entry by hand) instead of doing it.

## Step 3: Confirm one item at a time

If `SESSION_KIND` is `headless` or `spawned`, stop after Step 2: report the
audit and move nothing.

Otherwise walk the candidates in rank order. For each one, show its row and
the evidence, then ask with AskUserQuestion:

- Question: "Move `<path>` to the gc trash? Signal: `<signal>`."
- Options: ["Trash it", "Skip", "Stop here"]

There is no "all" option, and one answer never covers the next item. Skip the
`mcp` rows here — Step 2 already named the action. "Stop here" ends the walk;
report what was done so far.

## Step 4: Soft-delete the confirmed item

For a skill, hook or cache path:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-gc" trash '<PATH from the row>'
```

The bin moves it to `~/.vibestack/gc-trash/<date>/<channel>/` and appends an
`undo:` line to `~/.vibestack/gc-log.md`. A `REFUSED:` line means the path is
settings, MCP configuration, transcripts, project state, a pack-owned skill or
outside the known roots — nothing moved. Report the refusal; never move the
path by other means.

For a permission entry, write the exact entry to
`~/.vibestack/gc-entry.txt` with the Write tool (no trailing newline), then
run this with the settings file the row named:

```bash
_SETTINGS='<settings file path from the row>'
_DAY=$(date +%Y-%m-%d)
_VH="${VIBESTACK_HOME:-$HOME/.vibestack}"
_BACKUP="$_VH/gc-trash/$_DAY/permissions/$(basename "$_SETTINGS").$(date +%H%M%S)"
mkdir -p "$(dirname "$_BACKUP")" && cp "$_SETTINGS" "$_BACKUP" || { echo "BACKUP_FAILED"; exit 1; }
python3 -I -c '
import json, os, sys
settings, entry_file = sys.argv[1], sys.argv[2]
entry = open(entry_file, encoding="utf-8").read()
with open(settings, encoding="utf-8") as f:
    data = json.load(f)
allow = data.get("permissions", {}).get("allow", [])
if entry not in allow:
    sys.exit("ENTRY_NOT_FOUND")
i = len(allow) - 1 - allow[::-1].index(entry)
del allow[i]
# The new file takes the original mode, so the rename cannot widen a 0600 file.
fd = os.open(settings + ".gc-tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, os.stat(settings).st_mode & 0o7777)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
' "$_SETTINGS" "$_VH/gc-entry.txt" || { echo "EDIT_FAILED"; exit 1; }
mv "$_SETTINGS.gc-tmp" "$_SETTINGS"
python3 -I -c '
import datetime, sys
log, settings, backup, entry_file = sys.argv[1:5]
entry = open(entry_file, encoding="utf-8").read()
ts = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
with open(log, "a", encoding="utf-8") as f:
    f.write("- %s removed permission %r from %s; backup %s undo: cp %r %r\n" % (ts, entry, settings, backup, backup, settings))
' "$_VH/gc-log.md" "$_SETTINGS" "$_BACKUP" "$_VH/gc-entry.txt"
rm -f "$_VH/gc-entry.txt"
echo "REMOVED_FROM: $_SETTINGS"
echo "BACKUP: $_BACKUP"
```

Only the last occurrence of a duplicate is removed, so one entry stays. On
`BACKUP_FAILED`, `ENTRY_NOT_FOUND` or `EDIT_FAILED` the settings file is
unchanged — report it and go on to the next item.

## Step 5: Report

```
vibe-gc — <date>
Moved:      <n> items (<reclaimed KB> KB)
  - <path> → <trash path>
Permissions removed: <n> (backups in gc-trash/<date>/permissions/)
Skipped:    <n>
Automation: <one line per server/hook with its status and the owner's action>
Undo:       "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-gc" undo <date>   (moves that day's items back)
            permission edits: copy the backup named in gc-log.md over the settings file
Next review: <date + 30 days>
```

## Important Rules

- **Audit-only by default.** Nothing moves without a per-item confirmation in
  an interactive session.
- **Pack-owned skills are never candidates.** A name in a root's
  `.vibestack-manifest` belongs to the pack; `./install` manages it.
- **Stale is not disposable.** A failed connection or an old timestamp is
  evidence to show, not a verdict.
- **Unmeasured usage is not unused.** Only a measured absence of use counts as
  a signal.
- **Never hard-delete.** The trash and the log are the undo path.
- **Sources and repos are never touched**, nor MCP, n8n, cron or launchd
  state.
