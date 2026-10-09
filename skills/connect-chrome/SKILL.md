---
name: connect-chrome
description: |
  Reuse your real Chrome's logged-in cookies in the browse daemon, so authenticated pages work without re-logging-in.
allowed-tools:
  - Bash
triggers:
  - connect to chrome
  - use my chrome session
  - reuse browser login
  - import chrome cookies
  - browse as me
---

## When to invoke

Use when the browse daemon needs to act as your logged-in self — reuse the
cookies/sessions from your real Chrome (e.g. QA-ing a page behind a login)
without typing credentials into the automated browser.

# /connect-chrome — Reuse your Chrome session

{{include lib/snippets/browse-setup.md}}

If `BROWSE_NOT_AVAILABLE`: tell the user the browse shim is required and stop.

### 1. Probe for the direct cookie import

`$B` resolves to the full browse daemon when its dependencies are installed, and
to the stateless shim otherwise. Only the full daemon can read the installed
browser's cookie database directly, so probe for it with the site the user
wants (a bare hostname, e.g. `github.com`):

```bash
B='<BROWSE_BIN>'
"$B" cookie-import-browser --domain '<site>'
```

- **Any other answer** (an import, or an error such as a domain mismatch or a
  missing browser name): the full daemon is up, and this is the path — it reads
  the installed browser's cookie store directly, no relaunch, no debugging port.
  Do not retry the import here; the browser and profile are the user's choice.
  Hand off to `/setup-browser-cookies` for the picker, and stop here.
- **It prints `NOT_SUPPORTED:cookie-import-browser`**: the stateless shim is
  running. Continue with the CDP path below.

### 2. Shim only: start Chrome with remote debugging

Chrome 136 and later refuse `--remote-debugging-port` on the default profile.
The port only opens with a separate `--user-data-dir`, and that profile starts
empty — none of the user's logins. Say so plainly: the user must sign in once
in that window before the import has anything to copy.

Ask the user to launch Chrome with a debugging port and its own profile dir:

- **macOS:** `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=9222 --user-data-dir="$HOME/.chrome-debug-profile"`
- **Linux:** `google-chrome --remote-debugging-port=9222 --user-data-dir="$HOME/.chrome-debug-profile"`
- **Windows:** `chrome.exe --remote-debugging-port=9222 --user-data-dir=%USERPROFILE%\chrome-debug-profile`

Then have them sign in to the target site in that window. Confirm the port is
reachable:

```bash
curl -s http://127.0.0.1:9222/json/version >/dev/null 2>&1 && echo "CHROME_CDP_OK" || echo "CHROME_CDP_UNREACHABLE"
```

If `CHROME_CDP_UNREACHABLE`: the port differs or Chrome isn't in debug mode — ask
the user to confirm the launch flags and port.

### 3. Shim only: start the daemon and import the cookies

```bash
B='<BROWSE_BIN>'
"$B" daemon >/dev/null 2>&1 &        # persistent session (skip if already running)
sleep 1
"$B" cookies import-cdp http://127.0.0.1:9222
```

### 4. Shim only: verify

Navigate to a page that requires login and confirm you're signed in:

```bash
B='<BROWSE_BIN>'
"$B" goto <authenticated-url>
"$B" snapshot          # look for signed-in markers (account name, logout link)
```

Report whether the session carried over. Stop the daemon with `"$B" daemon-stop`
when done. Cookies stay in the daemon's session only — they are never written to
the repo or logged.
