---
name: open-browser
description: |
  Open a visible browser window you can watch while the agent drives it, with a live activity sidebar.
triggers:
  - open browser
  - launch chromium
  - show me the browser
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

If this session was compacted, the copy of this skill in context may be cut off.
Read `${CLAUDE_SKILL_DIR}/SKILL.md` from disk and resume at the step you are on.

## When to invoke

Use when asked to "open browser", "launch browser", "connect chrome", "open chrome", "real browser", "launch chrome", "side panel", or "control my browser".

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

# /open-browser — Launch vibestack Browser

Launch vibestack Browser — AI-controlled Chromium with the sidebar extension,
anti-bot stealth, and real-time visibility. You see every action as it happens.

## SETUP (run this check BEFORE any browse command)

```bash
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
B=""
# install renders each skill to <root>/skills/<name>/ and links its bin/ — there
# is no skills/vibestack/ directory and no dist/browse, so the previous paths
# could never resolve and this skill always dead-ended at NEEDS_SETUP.
[ -n "$_ROOT" ] && [ -x "$_ROOT/.claude/skills/browse/bin/vibe-browse" ] && B="$_ROOT/.claude/skills/browse/bin/vibe-browse"
[ -z "$B" ] && [ -x "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/open-browser}/../browse/bin/vibe-browse" ] && B="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/open-browser}/../browse/bin/vibe-browse"
[ -z "$B" ] && B="$(command -v vibe-browse || true)"
if [ -x "$B" ]; then echo "READY: $B"; echo "BROWSE_BIN: $B"; else echo "NEEDS_SETUP"; fi
```

Every Bash call starts a fresh shell, so `$B` is unset in every later block.
A block that runs a browse command starts with `B='<BROWSE_BIN>'`: replace
`<BROWSE_BIN>` with the path printed on the `BROWSE_BIN:` line.

If `NEEDS_SETUP`, or a later `$B connect` prints `BROWSE_NOT_AVAILABLE`, stop
and name the cause it printed. The browse daemon ships with vibestack under
`browse/`; what can be missing is its runtime:

- `bun not found` — the headed browser needs the full daemon, which runs on bun.
  Install bun, then re-run.
- `dependencies not installed` — run `bun install` in the vibestack checkout
  (the path it printed); that also fetches Playwright's Chromium on first use.
- the launcher itself is missing — the install skipped the browse skill; re-run
  `./install`.

The stateless fallback shim (node + npm) cannot open a headed window, so it is
no workaround here. See [`docs/external-tools.md`](../../docs/external-tools.md#browse-daemon).

---

## Step 0: Check for a running browse daemon

A running browse daemon may hold open tabs, cookies and signed-in sessions —
cookies imported with /setup-browser-cookies, a remote agent paired through
/pair-agent — and replacing it loses all of them. Never kill it, and never
delete its state file, to get it out of the way. Probe without starting one
(`BROWSE_NO_AUTOSTART=1` keeps `status` from booting a daemon):

```bash
B='<BROWSE_BIN>'
_STATUS=$(BROWSE_NO_AUTOSTART=1 $B status 2>&1); _STATUS_RC=$?
printf '%s\n' "$_STATUS" | head -5
if [ "$_STATUS_RC" -ne 0 ]; then echo "DAEMON: none"
elif printf '%s' "$_STATUS" | grep -q 'Mode: headed'; then echo "DAEMON: headed"
else echo "DAEMON: live"; fi
```

- **`DAEMON: none`**: no daemon answered. Run Step 1's plain `$B connect`. Do
  not delete the Chromium profile's lock files yourself: another project's
  vibestack Browser may hold them. The CLI cleans up stale state itself — a
  lock whose browser is gone, or an orphaned browser whose daemon died — and it
  refuses, killing and deleting nothing, when a live browser it does not own
  holds the profile or a daemon is alive but too busy to answer. If it refuses,
  show its output and stop.

- **`DAEMON: headed`**: vibestack Browser is already open. Step 1's plain
  `$B connect` reports that; continue to Step 2.

- **`DAEMON: live`**: a headless daemon is running. With `SESSION_KIND:
  spawned` or `headless`, do not ask and do not replace it. Print this and
  stop:

  ```bash
  B='<BROWSE_BIN>'
  printf 'Live browse daemon left running. Run %s stop, then re-run /open-browser to replace it.\n' "$B"
  ```

  Otherwise AskUserQuestion. Replacing the daemon cannot be undone:

  > "A browse daemon is already running (tabs and logins may be active).
  > Opening vibestack Browser replaces it, and everything in that daemon is
  > lost."
  >
  > RECOMMENDATION: Choose B unless you are done with the running session.

  Options:
  - A) Replace it (runs `$B connect --force-restart`; its tabs, cookies and logins are lost)
  - B) Keep it running and stop here

  Only an explicit A runs Step 1 with `--force-restart`. On B, or on a reply
  that is not clearly A, print the "Live browse daemon left running" line above
  and stop.

## Step 1: Connect

```bash
B='<BROWSE_BIN>'
$B connect
```

After an explicit A in Step 0, and only then:

```bash
B='<BROWSE_BIN>'
$B connect --force-restart
```

This launches vibestack Browser (rebranded Chromium) in headed mode with:
- A visible window you can watch (not your regular Chrome — it stays untouched)
- The sidebar extension auto-loaded via `launchPersistentContext`
- Anti-bot stealth patches (sites like Google and NYTimes work without captchas)
- Custom user agent in Dock/menu bar
- A Side Panel whose main surface is a real `claude` terminal (a PTY on this
  machine), with browser quick-action buttons above it

The `connect` command auto-discovers the extension from the install directory.
It always uses port **34567** so the extension can auto-connect.

After connecting, print the full output to the user. Confirm you see
`Mode: headed` in the output.

If the output shows an error or the mode is not `headed`, run `$B status` and
share the output with the user before proceeding.

## Step 2: Verify

```bash
B='<BROWSE_BIN>'
$B status
```

Confirm the output shows `Mode: headed`. Read the port from the state file:

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
_STATE_FILE=""
[ -n "$_REPO_ROOT" ] && [ -f "$_REPO_ROOT/.vibestack/browse.json" ] && _STATE_FILE="$_REPO_ROOT/.vibestack/browse.json"
[ -z "$_STATE_FILE" ] && _STATE_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/browse.json"
grep -o '"port":[0-9]*' "$_STATE_FILE" 2>/dev/null | grep -o '[0-9]*'
```

The port should be **34567**. If it's different, note it — the user may need it
for the Side Panel.

Also find the extension path so you can help the user if they need to load it manually:

```bash
_EXT_PATH=""
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
# Same correction as the binary above: the extension lives in the checkout, and
# the skill reaches it through the repo root, never through a skills/vibestack/
# directory that install does not create.
[ -n "$_ROOT" ] && [ -f "$_ROOT/extension/manifest.json" ] && _EXT_PATH="$_ROOT/extension"
[ -z "$_EXT_PATH" ] && [ -f "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/open-browser}/extension/manifest.json" ] && _EXT_PATH="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/open-browser}/extension"
echo "EXTENSION_PATH: ${_EXT_PATH:-NOT FOUND}"
```

## Step 3: Guide the user to the Side Panel

Use AskUserQuestion:

> Chrome is launched with vibestack control. You should see Playwright's Chromium
> (not your regular Chrome) with a shimmer line at the top of the page.
>
> The Side Panel extension should be auto-loaded. To open it:
> 1. Look for the **puzzle piece icon** (Extensions) in the toolbar
> 2. Click the **puzzle piece** → find **vibestack browse** → click the **pin icon**
> 3. Click the pinned icon in the toolbar
> 4. The Side Panel opens on the right with a terminal running `claude`
>
> **Port:** 34567 (auto-detected — the extension connects automatically in the
> Playwright-controlled Chrome).

Options:
- A) I can see the Side Panel — let's go!
- B) I can see Chrome but can't find the extension
- C) Something went wrong

If B: Tell the user:

> The extension is loaded into Playwright's Chromium at launch time, but
> sometimes it doesn't appear immediately. Try these steps:
>
> 1. Type `chrome://extensions` in the address bar
> 2. Look for the **vibestack browse** extension — it should be listed and enabled
> 3. If it's there but not pinned, go back to any page, click the puzzle piece
>    icon, and pin it
> 4. If it's NOT listed at all, click **"Load unpacked"** and navigate to:
>    - Press **Cmd+Shift+G** in the file picker dialog
>    - Paste this path: `{EXTENSION_PATH}` (use the path from Step 2)
>    - Click **Select**
>
> After loading, pin it and click the icon to open the Side Panel.
>
> If the Side Panel badge stays gray (disconnected), click the icon
> and enter port **34567** manually.

If C:

1. Run `$B status` and show the output
2. If the server is not healthy, re-run Step 0 (probe, and ask before any
   replacement) and then Step 1 connect
3. If the server IS healthy but the browser isn't visible, try `$B focus`
4. If that fails, ask the user what they see (error message, blank screen, etc.)

## Step 4: Demo

After the user confirms the Side Panel is working, run a quick demo:

```bash
B='<BROWSE_BIN>'
$B goto https://github.com
```

Wait 2 seconds, then:

```bash
B='<BROWSE_BIN>'
$B snapshot -i
```

Tell the user: "Click **debug** in the Side Panel footer and open the
**Activity** tab — the `goto` and `snapshot` commands are listed there. Every
command Claude runs shows up in real time."

## Step 5: The Side Panel terminal

Tell the user what the Side Panel holds:

> The Side Panel runs a real **Claude Code terminal** (`claude` in a PTY on this
> machine, working in the browser you see). Type to it like any terminal.
> If it shows "Claude Code not found", install the `claude` CLI and click
> "I installed it — try again". **↻ Restart** starts a fresh session; the size
> picker next to it changes the text size.
>
> Buttons above the terminal act on the current page:
> - **Cleanup** removes ads, cookie banners and pop-ups
> - **Screenshot** captures the page
> - **Cookies** opens the cookie picker to import a signed-in session from your
>   own browser (the same flow as /setup-browser-cookies)
>
> The **debug** toggle in the footer opens three more tabs: **Activity** (every
> browse command as it runs), **Refs** (the `@e` refs from the last snapshot)
> and **Inspector** (pick an element to see its box model and CSS rules).

## Step 6: What's next

Tell the user:

> You're all set. With the connected browser you can:
>
> - Run any vibestack skill (`/qa`, `/design-review`, `/benchmark`) and watch
>   every page load and click in the visible window; the Activity tab logs each
>   command
> - Drive it directly: `$B goto <url>`, `$B click <sel>`, `$B fill <sel> <val>`,
>   `$B snapshot -i`
> - `$B focus` brings the window to the front; `$B disconnect` closes it and
>   returns to headless mode
>
> The browser keeps its own profile, separate from your regular Chrome. Import
> a signed-in session with **Cookies** or /setup-browser-cookies when a test
> needs one.

Then proceed with whatever the user asked to do. If they didn't specify a task,
ask what they'd like to test or browse.
