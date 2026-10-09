---
name: setup-browser-cookies
description: |
  Import cookies from your real Chromium browser into the headless browse session. Opens an interactive picker UI where you select which cookie domains to import. Use before QA testing authenticated pages.
triggers:
  - import browser cookies
  - login to test site
  - setup authenticated session
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

## When to invoke

Use when asked to "import cookies", "login to the site", or "authenticate the browser".

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

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

# Setup Browser Cookies

Import logged-in sessions from your real Chromium browser into the headless browse session.

## CDP mode check

First, check if browse is already connected to the user's real browser:
```bash
$B status 2>/dev/null | grep -q "Mode: cdp" && echo "CDP_MODE=true" || echo "CDP_MODE=false"
```
If `CDP_MODE=true`: tell the user "Not needed — you're connected to your real browser via CDP. Your cookies and sessions are already available." and stop. No cookie import needed.

## How it works

1. Find the browse binary
2. Run `cookie-import-browser` to detect installed browsers and open the picker UI
3. User selects which cookie domains to import in their browser
4. Cookies are decrypted and loaded into the Playwright session

## Steps

### 1. Find the browse binary

```bash
B="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/setup-browser-cookies}/../browse/bin/vibe-browse"
[ -x "$B" ] || B="$(command -v vibe-browse || true)"
if [ -n "$B" ] && [ -x "$B" ] && [ "$("$B" status 2>/dev/null)" != "BROWSE_NOT_AVAILABLE" ]; then
  echo "READY: $B"
else
  echo "NEEDS_SETUP"
fi
```

If `NEEDS_SETUP`, stop and tell the user the browse binary could not be found or
could not start — node is missing, or first-run setup was declined.

Cookie import needs the full browse daemon; the stateless fallback shim cannot
decrypt a real browser's cookie store. If any command below answers
`NOT_SUPPORTED:cookie-import-browser`, that is what happened: tell the user the
full daemon is not running in this checkout and stop, rather than reporting a
half-import that never occurred.

### 2. Open the cookie picker

```bash
$B cookie-import-browser
```

This auto-detects installed Chromium browsers and opens
an interactive picker UI in your default browser where you can:
- Switch between installed browsers
- Search domains
- Click "+" to import a domain's cookies
- Click trash to remove imported cookies

Tell the user: **"Cookie picker opened — choose the browser, the profile, and the domains you want to import, then tell me when you're done."**

The choice of browser, profile and domains is the user's. Never pick one for
them, and never treat whichever browser the CLI falls back to as consent. A
profile you could not read is unknown, not empty.

### 3. Direct import (alternative)

If the user names a domain directly (e.g., `/setup-browser-cookies github.com`),
skip the UI — but only with a browser the user named. If they did not name one,
ask via AskUserQuestion which browser to import from — this path skips the
picker, so you have no detected list: name the supported ones (Chrome, Chromium,
Arc, Brave, Edge, Comet) and let the user answer; never fill one in yourself. The import is scoped to the page the daemon is on,
so navigate to the domain first:

```bash
$B goto https://github.com
$B cookie-import-browser <browser> --domain github.com
```

`<browser>` is the one the user chose. `--profile` takes a profile directory
(`Default`, `Profile 1`), not a display name; omit it only when the user's
browser has a single relevant profile, otherwise use the picker. `--all` imports
every non-expired cookie from the browser — run it only when the user asked for
exactly that.

### 4. Report honestly

Report what the import itself returned: the receipt line (`Imported N cookies
for <domain> from <browser>`, plus any `failed to decrypt` count) or the picker's
per-domain counts, and say plainly when an import was partial, zero, or errored.

Never run `$B cookies` or `$B storage` to "show what was imported", and never
put a cookie value, token, password, or session detail into the transcript or a
report. Counts and domain names are the whole summary.

Keep three states apart, and name the one you are in:

- **Not checked** — cookies were copied; nobody looked at whether they sign you in.
- **Not verified** — you checked, and the target did not show a signed-in state.
- **Verified** — a page on the target showed positive signed-in evidence (an
  account-only page rendered instead of the sign-in wall).

An import count, a zero-error import, or an HTTP 200 never proves a login.
Stop at **Not checked** unless the user asked you to check.

## Notes

- On macOS, the first import per browser may trigger a Keychain dialog — click "Allow" / "Always Allow"
- On Linux, `v11` cookies may require `secret-tool`/libsecret access; `v10` cookies use Chromium's standard fallback key
- Cookie picker is served on the same port as the browse server (no extra process)
- Only domain names and cookie counts are shown in the UI — no cookie values are exposed
- The browse session persists cookies between commands, so imported cookies work immediately
