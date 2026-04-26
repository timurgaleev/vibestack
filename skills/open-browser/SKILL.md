---
name: open-browser
description: |
  Launch vibestack Browser — AI-controlled Chromium with the sidebar extension baked in.
  Opens a visible browser window where you can watch every action in real time.
  The sidebar shows a live activity feed and chat. Anti-bot stealth built in.
  Use when asked to "open browser", "launch browser", "connect chrome",
  "open chrome", "real browser", "launch chrome", "side panel", or "control my browser".
triggers:
  - open browser
  - launch chromium
  - show me the browser
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

## Preamble

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.vibestack/bin/vibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

# /open-browser — Launch vibestack Browser

Launch vibestack Browser — AI-controlled Chromium with the sidebar extension,
anti-bot stealth, and real-time visibility. You see every action as it happens.

## SETUP (run this check BEFORE any browse command)

```bash
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
B=""
[ -n "$_ROOT" ] && [ -x "$_ROOT/.claude/skills/vibestack/browse/dist/browse" ] && B="$_ROOT/.claude/skills/vibestack/browse/dist/browse"
[ -z "$B" ] && B="$HOME/.claude/skills/vibestack/browse/dist/browse"
if [ -x "$B" ]; then echo "READY: $B"; else echo "NEEDS_SETUP"; fi
```

If `NEEDS_SETUP`, stop and tell the user:
"The browse binary is not installed. Build it by running: `cd ~/.claude/skills/vibestack && ./setup` (~10 seconds)."

---

## Step 0: Pre-flight cleanup

Before connecting, kill any stale browse servers and clean up lock files that
may have persisted from a crash. This prevents "already connected" false
positives and Chromium profile lock conflicts.

```bash
# Kill any existing browse server
_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
_BROWSE_STATE=""
[ -n "$_REPO_ROOT" ] && _BROWSE_STATE="$_REPO_ROOT/.vibestack/browse.json"
[ -z "$_BROWSE_STATE" ] || [ ! -f "$_BROWSE_STATE" ] && _BROWSE_STATE="$HOME/.vibestack/browse.json"
if [ -f "$_BROWSE_STATE" ]; then
  _OLD_PID=$(grep -o '"pid":[0-9]*' "$_BROWSE_STATE" 2>/dev/null | grep -o '[0-9]*')
  [ -n "$_OLD_PID" ] && kill "$_OLD_PID" 2>/dev/null || true
  sleep 1
  [ -n "$_OLD_PID" ] && kill -9 "$_OLD_PID" 2>/dev/null || true
  rm -f "$_BROWSE_STATE"
fi
# Clean Chromium profile locks (can persist after crashes)
_PROFILE_DIR="$HOME/.vibestack/chromium-profile"
for _LF in SingletonLock SingletonSocket SingletonCookie; do
  rm -f "$_PROFILE_DIR/$_LF" 2>/dev/null || true
done
echo "Pre-flight cleanup done"
```

## Step 1: Connect

```bash
$B connect
```

This launches vibestack Browser (rebranded Chromium) in headed mode with:
- A visible window you can watch (not your regular Chrome — it stays untouched)
- The sidebar extension auto-loaded via `launchPersistentContext`
- Anti-bot stealth patches (sites like Google and NYTimes work without captchas)
- Custom user agent in Dock/menu bar
- A sidebar agent process for chat commands

The `connect` command auto-discovers the extension from the install directory.
It always uses port **34567** so the extension can auto-connect.

After connecting, print the full output to the user. Confirm you see
`Mode: headed` in the output.

If the output shows an error or the mode is not `headed`, run `$B status` and
share the output with the user before proceeding.

## Step 2: Verify

```bash
$B status
```

Confirm the output shows `Mode: headed`. Read the port from the state file:

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
_STATE_FILE=""
[ -n "$_REPO_ROOT" ] && [ -f "$_REPO_ROOT/.vibestack/browse.json" ] && _STATE_FILE="$_REPO_ROOT/.vibestack/browse.json"
[ -z "$_STATE_FILE" ] && _STATE_FILE="$HOME/.vibestack/browse.json"
grep -o '"port":[0-9]*' "$_STATE_FILE" 2>/dev/null | grep -o '[0-9]*'
```

The port should be **34567**. If it's different, note it — the user may need it
for the Side Panel.

Also find the extension path so you can help the user if they need to load it manually:

```bash
_EXT_PATH=""
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -n "$_ROOT" ] && [ -f "$_ROOT/.claude/skills/vibestack/extension/manifest.json" ] && _EXT_PATH="$_ROOT/.claude/skills/vibestack/extension"
[ -z "$_EXT_PATH" ] && [ -f "$HOME/.claude/skills/vibestack/extension/manifest.json" ] && _EXT_PATH="$HOME/.claude/skills/vibestack/extension"
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
> 4. The Side Panel should open on the right showing a live activity feed
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
2. If the server is not healthy, re-run Step 0 cleanup + Step 1 connect
3. If the server IS healthy but the browser isn't visible, try `$B focus`
4. If that fails, ask the user what they see (error message, blank screen, etc.)

## Step 4: Demo

After the user confirms the Side Panel is working, run a quick demo:

```bash
$B goto https://github.com
```

Wait 2 seconds, then:

```bash
$B snapshot -i
```

Tell the user: "Check the Side Panel — you should see the `goto` and `snapshot`
commands appear in the activity feed. Every command Claude runs shows up here
in real time."

## Step 5: Sidebar chat

After the activity feed demo, tell the user about the sidebar chat:

> The Side Panel also has a **chat tab**. Try typing a message like "take a
> snapshot and describe this page." A sidebar agent (a child Claude instance)
> executes your request in the browser — you'll see the commands appear in
> the activity feed as they happen.
>
> The sidebar agent can navigate pages, click buttons, fill forms, and read
> content. Each task gets up to 5 minutes. It runs in an isolated session, so
> it won't interfere with this Claude Code window.

## Step 6: What's next

Tell the user:

> You're all set! Here's what you can do with the connected Chrome:
>
> **Watch Claude work in real time:**
> - Run any vibestack skill (`/qa`, `/design-review`, `/benchmark`) and watch
>   every action happen in the visible Chrome window + Side Panel feed
> - No cookie import needed — the Playwright browser shares its own session
>
> **Control the browser directly:**
> - **Sidebar chat** — type natural language in the Side Panel and the sidebar
>   agent executes it (e.g., "fill in the login form and submit")
> - **Browse commands** — `$B goto <url>`, `$B click <sel>`, `$B fill <sel> <val>`,
>   `$B snapshot -i` — all visible in Chrome + Side Panel
>
> **Window management:**
> - `$B focus` — bring Chrome to the foreground anytime
> - `$B disconnect` — close headed Chrome and return to headless mode
>
> **What skills look like in headed mode:**
> - `/qa` runs its full test suite in the visible browser — you see every page
>   load, every click, every assertion
> - `/design-review` takes screenshots in the real browser — same pixels you see
> - `/benchmark` measures performance in the headed browser

Then proceed with whatever the user asked to do. If they didn't specify a task,
ask what they'd like to test or browse.
