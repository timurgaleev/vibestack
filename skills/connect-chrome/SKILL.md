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

### 1. Start Chrome with remote debugging

Ask the user to launch (or relaunch) Chrome with a debugging port — this exposes
its cookies over CDP without leaking the password:

- **macOS:** `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=9222`
- **Linux:** `google-chrome --remote-debugging-port=9222`
- **Windows:** `chrome.exe --remote-debugging-port=9222`

Confirm it is reachable:

```bash
curl -s http://127.0.0.1:9222/json/version >/dev/null 2>&1 && echo "CHROME_CDP_OK" || echo "CHROME_CDP_UNREACHABLE"
```

If `CHROME_CDP_UNREACHABLE`: the port differs or Chrome isn't in debug mode — ask
the user to confirm the launch flag and port.

### 2. Start the daemon and import the cookies

```bash
"$B" daemon >/dev/null 2>&1 &        # persistent session (skip if already running)
sleep 1
"$B" cookies import-cdp http://127.0.0.1:9222
```

### 3. Verify

Navigate to a page that requires login and confirm you're signed in:

```bash
"$B" goto <authenticated-url>
"$B" snapshot          # look for signed-in markers (account name, logout link)
```

Report whether the session carried over. Stop the daemon with `"$B" daemon-stop`
when done. Cookies stay in the daemon's session only — they are never written to
the repo or logged.
