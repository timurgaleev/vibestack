#!/usr/bin/env bash
# test-browse-shim — checks the stateless Playwright `$B` shim.
#
# Browser-free assertions (dispatch, NOT_SUPPORTED, usage, context verbs,
# detection sentinel) always run. The full-render of live capture verbs runs
# only when a Playwright install is discoverable — set VIBE_BROWSE_DEP_DIR to a
# dir containing node_modules/playwright to exercise them; otherwise skipped.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RT="$REPO_ROOT/skills/browse/runtime/vibe-browse.mjs"
LAUNCHER="$REPO_ROOT/skills/browse/bin/vibe-browse"

PASS=0
FAIL=0
FAILS=()
pass() { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILS+=("$1: $2"); printf '  FAIL %s — %s\n' "$1" "$2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_BROWSE_CTX_DIR="$WORK/ctx"

# out <expected-substr> <expected-exit> <name> -- <argv...>
out() {
  local want="$1" want_exit="$2" name="$3"; shift 4
  local got code
  got="$(node "$RT" "$@" 2>&1)"; code=$?
  if [ "$code" != "$want_exit" ]; then
    fail "$name" "exit $code != $want_exit ($got)"; return
  fi
  if [ -n "$want" ] && ! printf '%s' "$got" | grep -qF "$want"; then
    fail "$name" "missing '$want' in: $got"; return
  fi
  pass "$name"
}

echo "== browser-free =="
out "Mode: launched"     0 "status"            -- status
out "NOT_SUPPORTED:click" 2 "unsupported-click" -- click @e3
out "NOT_SUPPORTED:snapshot" 2 "unsupported-snapshot" -- snapshot -i
out "usage"              2 "no-verb"           --
out "NOT_SUPPORTED:bogus" 2 "unknown-verb"     -- bogus
out "viewport set 375x812" 0 "viewport-set"    -- viewport 375x812
# goto records URL even with no browser? No — goto loads. url reads ctx only:
node "$RT" viewport 800x600 >/dev/null 2>&1
out "" 0 "url-empty-ok" -- url   # no url yet → prints empty, exit 0

echo "== launcher detection =="
# Missing runtime → BROWSE_NOT_AVAILABLE, exit 0 (degradable).
miss="$(VIBESTACK_HOME="$WORK/home" bash -c '
  SELF_DIR="'"$WORK"'/fakebin"; mkdir -p "$SELF_DIR/../runtime" 2>/dev/null
  cp "'"$LAUNCHER"'" "$SELF_DIR/vibe-browse"
  rm -f "'"$WORK"'/runtime/vibe-browse.mjs"
  "$SELF_DIR/vibe-browse" status 2>&1' )"
if printf '%s' "$miss" | grep -qF "BROWSE_NOT_AVAILABLE"; then
  pass "launcher-missing-runtime-sentinel"
else
  fail "launcher-missing-runtime-sentinel" "got: $miss"
fi

echo "== live capture (needs Playwright) =="
PW=""
[ -n "${VIBE_BROWSE_DEP_DIR:-}" ] && [ -f "${VIBE_BROWSE_DEP_DIR}/node_modules/playwright/index.js" ] && PW=1
[ -f "$REPO_ROOT/node_modules/playwright/index.js" ] && PW=1
if [ -z "$PW" ]; then
  echo "  (skipped — no Playwright install found; set VIBE_BROWSE_DEP_DIR)"
else
  cat > "$WORK/p.html" <<'HTML'
<!doctype html><html><head><title>QA</title><style>#t{color:rgb(1,2,3)}</style></head>
<body><h1 id="t">Hi</h1><button id="b" disabled>x</button>
<script>console.error('ERRMARK')</script></body></html>
HTML
  ( cd "$WORK" && out "\"status\": 200" 0 "goto"        -- goto file://./p.html )
  ( cd "$WORK" && out "file://"         0 "url-after-goto" -- url )
  out "QA"            0 "js-title"          -- js "document.title"
  out "rgb(1, 2, 3)"  0 "css-color"         -- css "#t" color
  out "true"          0 "is-disabled"       -- is disabled "#b"
  out "false"         1 "is-visible-missing" -- is visible "#nope"
  out "ERRMARK"       1 "console-errors"    -- console --errors
  out "ttfb"          0 "perf"              -- perf
  node "$RT" screenshot "$WORK/s.png" >/dev/null 2>&1 \
    && [ -s "$WORK/s.png" ] && pass "screenshot-file" || fail "screenshot-file" "no png"
  node "$RT" responsive "$WORK/r" >/dev/null 2>&1 \
    && [ -s "$WORK/r-mobile.png" ] && [ -s "$WORK/r-desktop.png" ] \
    && pass "responsive-3" || fail "responsive-3" "missing viewport pngs"
fi

# daemon client: control + proxy verbs behave with NO daemon running.
export VIBE_BROWSE_DAEMON_SOCK="$WORK/no-daemon.sock"
node --check "$REPO_ROOT/skills/browse/runtime/vibe-browse-daemon.mjs" \
  && pass "daemon-syntax" || fail "daemon-syntax" "daemon runtime has a syntax error"
printf '%s' "$(node "$RT" daemon-status 2>&1)" | grep -q "no daemon" \
  && pass "daemon-status-none" || fail "daemon-status-none" "status wrong with no daemon"
node "$RT" click @e1 >/dev/null 2>&1; [ "$?" -eq 2 ] \
  && pass "interaction-needs-daemon" || fail "interaction-needs-daemon" "click should be NOT_SUPPORTED with no daemon"

# chain: supported (not NOT_SUPPORTED) and prints usage with no args
chain_out="$(node "$RT" chain 2>&1)"; chain_code=$?
if [ "$chain_code" -eq 1 ] && ! printf '%s' "$chain_out" | grep -q NOT_SUPPORTED \
   && printf '%s' "$chain_out" | grep -q "step verbs"; then
  pass "chain-usage"
else
  fail "chain-usage" "chain dispatch broken"
fi

echo ""
echo "== summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILS[@]}"
  exit 1
fi
