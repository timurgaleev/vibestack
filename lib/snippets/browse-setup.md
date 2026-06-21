**Find the browse binary:**

## SETUP

vibestack ships a stateless, Playwright-backed browse shim (`vibe-browse`).
Detect it, and bind `$B` to it when present:

```bash
# Prefer the shim installed alongside this skill; fall back to PATH.
B="${CLAUDE_SKILL_DIR}/../browse/bin/vibe-browse"
[ -x "$B" ] || B="$(command -v vibe-browse || true)"

if [ -n "$B" ] && [ -x "$B" ] && [ "$("$B" status 2>/dev/null)" != "BROWSE_NOT_AVAILABLE" ]; then
  echo "BROWSE_AVAILABLE via $B"
else
  echo "BROWSE_NOT_AVAILABLE"
fi
```

If `BROWSE_AVAILABLE`: use `$B` for all browse commands below. The shim is
**stateless** — `goto <url>` records the target, and each capture verb
(`screenshot`, `responsive`, `console`, `network`, `perf`, `js`, `css`, `is`,
`text`, `url`, `viewport`) re-navigates and captures fresh.

For **interaction**, use `$B chain` — a single call that runs a sequence of
steps on **one live page**, so a form fill → submit → screenshot works without
cross-call element refs:
`$B chain "goto <url>" "fill <sel> <value>" "click <sel>" "screenshot <path>"`.
Step verbs: `goto click fill type press hover check uncheck select wait
screenshot text eval is`. It returns a JSON log per step and stops on the first
failure. For a **persistent session with element refs** across separate calls, start the
daemon once: `$B daemon &` (then `$B daemon-status` to confirm, `$B daemon-stop`
to end it). With the daemon up, `$B snapshot` tags interactive elements and
returns `@e1`, `@e2`, …; later calls act on the same live page by ref —
`$B click @e3`, `$B fill @e2 "user@test.com"`, plus `hover/type/press/check/
select/back/forward/reload/upload/goto/screenshot/text`. This is the cross-call
interaction the stateless shim can't do.

- **upload:** `$B upload <sel|@ref> <path…>` sets file inputs.
- **dialog:** `$B dialog` reports the last JS dialog; `$B dialog dismiss` makes
  the next one dismiss (default accepts).
- **cookies:** `$B cookies get|set <json>|save <path>|load <path>|import-cdp <url>`.
  `import-cdp` copies cookies from a Chrome started with `--remote-debugging-port`
  (the CDP cookie-import path).

- **tunnel / pairing:** `$B tunnel <port>` exposes a local port for a remote
  agent via ngrok and prints `TUNNEL: <https url>` (`$B tunnel-stop` ends it).
  Prints `TUNNEL_NOT_AVAILABLE` if ngrok isn't installed.

Without a running daemon, ref-based verbs (`snapshot`, a bare `click` / `fill`,
…) print `NOT_SUPPORTED:<verb>` — skip that pass, don't fabricate the result.

If `BROWSE_NOT_AVAILABLE` (no Node, or first-run setup declined): fall back to
text-only checks. Do **not** trust a bare `curl` status — dev servers often
serve error pages with HTTP 200. Verify the response **body** (grep for the
app's error markers, e.g. an error-overlay string) before calling a page
healthy, and tell the user screenshots were unavailable.
