#!/usr/bin/env bash
# test-browser-skill-consent.sh — the browser skills ask before they destroy or
# expose a signed-in session.
#
# The browse daemon can hold imported cookies and logged-in tabs. Four skills
# touch it, and each one has a rule that only lives in its SKILL.md text:
#   /open-browser          probes the daemon and asks before replacing a live one
#   /pair-agent            asks before a relaunch; tunnel consent is daemon-enforced
#   /setup-browser-cookies never prints cookie values, never picks the browser
#   /browse                look-not-act consent, LOCAL hosts, credential rules
#
# The /open-browser probe is also executed against a stub `$B`, so a probe that
# boots a daemon, misreads the status, or kills a process fails here.
#
# Usage: test-browser-skill-consent.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -Eq -- "$1" "$2"; }
check() { if has "$2" "$3"; then ok "$1"; else no "$1"; fi; }
refute() { if has "$2" "$3"; then no "$1: $(grep -E -- "$2" "$3" | head -1)"; else ok "$1"; fi; }

render() {
  local name="$1" out="$TMP/$1.md"
  if ! "$ROOT/bin/vibe-render-skill" "$ROOT/skills/$name/SKILL.md" "$out" >/dev/null 2>&1; then
    echo "cannot render skills/$name/SKILL.md" >&2; exit 1
  fi
  printf '%s\n' "$out"
}

# section FILE START_RE END_RE — lines from START up to (not including) END.
section() { awk -v s="$2" -v e="$3" '$0 ~ s {on=1} on && $0 ~ e && !($0 ~ s) {on=0} on' "$1"; }

# fenced_bash FILE — only the contents of ```bash fences.
fenced_bash() { awk '/^[[:space:]]*```bash/ {on=1; next} /^[[:space:]]*```/ {on=0} on' "$1"; }

# ── /open-browser ────────────────────────────────────────────────────────────
echo "open-browser: Step 0 probes and asks"
OB="$(render open-browser)"
STEP0="$TMP/ob-step0.md"
section "$OB" '^## Step 0:' '^## Step 1:' > "$STEP0"
[ -s "$STEP0" ] || { echo "Step 0 not found in open-browser" >&2; exit 1; }

refute "Step 0 runs no kill" '(^|[^[:alnum:]_-])kill([[:space:]]|$)' <(fenced_bash "$STEP0")
refute "Step 0 deletes no browse state file" 'rm[[:space:]].*(browse\.json|_BROWSE_STATE)' "$STEP0"
check "Step 0 probes with BROWSE_NO_AUTOSTART=1" 'BROWSE_NO_AUTOSTART=1 \$B status' "$STEP0"
check "Step 0 asks before replacing a live daemon" 'AskUserQuestion' "$STEP0"
check "Step 0 never replaces the daemon in spawned/headless sessions" 'spawned.*headless.*do not ask' <(tr '\n' ' ' < "$STEP0")
check "replacement is gated on an explicit A" 'Only an explicit A' "$STEP0"
check "Step 1 has the --force-restart connect" '^\$B connect --force-restart$' <(section "$OB" '^## Step 1:' '^## Step 2:')

# Execute the probe block against a stub $B. The stub records the env it saw
# and answers according to STUB_MODE.
PROBE="$TMP/probe.sh"
awk '/^```bash/ && !done {on=1; next} /^```/ && on {on=0; done=1} on' "$STEP0" > "$PROBE"
[ -s "$PROBE" ] || no "Step 0 probe block not found"
STUB="$TMP/stub-b"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s %s\n' "${BROWSE_NO_AUTOSTART:-unset}" "$*" >> "$STUB_LOG"
case "$STUB_MODE" in
  none)   echo "[browse] Server not available and BROWSE_NO_AUTOSTART is set." >&2; exit 1 ;;
  headed) printf 'Status: healthy\nMode: headed\n' ;;
  live)   printf 'Status: healthy\nMode: launched\n' ;;
esac
STUBEOF
chmod +x "$STUB"

run_probe() {
  STUB_MODE="$1" STUB_LOG="$TMP/stub.log" B="$STUB" bash -c "$(cat "$PROBE")" 2>&1 | grep '^DAEMON:'
}
for mode in none headed live; do
  : > "$TMP/stub.log"
  got="$(run_probe "$mode")"
  [ "$got" = "DAEMON: $mode" ] && ok "probe classifies $mode" || no "probe on $mode said '${got:-nothing}'"
  if [ "$(cat "$TMP/stub.log")" = "1 status" ]; then
    ok "probe on $mode only ran 'status' with BROWSE_NO_AUTOSTART=1"
  else
    no "probe on $mode ran: $(tr '\n' ';' < "$TMP/stub.log")"
  fi
done

# ── /pair-agent ──────────────────────────────────────────────────────────────
echo "pair-agent: relaunch consent and tunnel enforcement"
PA="$(render pair-agent)"
STEP4="$TMP/pa-step4.md"
section "$PA" '^## Step 4:' '^## Step 5:' > "$STEP4"
[ -s "$STEP4" ] || { echo "Step 4 not found in pair-agent" >&2; exit 1; }
CONSENT="$TMP/pa-consent.md"
section "$STEP4" '^## Step 4:' '^### If same machine' > "$CONSENT"

check "live-daemon consent precedes the pairing commands" 'Live-daemon consent' "$CONSENT"
check "consent asks via AskUserQuestion" 'AskUserQuestion' "$CONSENT"
check "--force-restart only after an explicit A" 'Only add `--force-restart`.*explicit' <(tr '\n' ' ' < "$CONSENT")
check "consent probe does not boot a daemon" 'BROWSE_NO_AUTOSTART=1 \$B status' "$CONSENT"
check "no relaunch question in spawned/headless sessions" 'spawned.*headless.*do not ask' <(tr '\n' ' ' < "$CONSENT")
refute "consent block never runs --force-restart itself" '--force-restart' <(fenced_bash "$CONSENT")
check "tunnel consent says the daemon refuses /tunnel/start" 'refuses `/tunnel/start`' "$STEP4"
check "tunnel consent says BROWSE_TUNNEL=1 is ignored" 'ignores[[:space:]]*$|ignores `BROWSE_TUNNEL=1`' "$STEP4"
check "agent must not flip pair_agent itself" 'Never set the flag yourself' "$STEP4"
check "agent must not export the env override either" 'not `VIBESTACK_PAIR_AGENT=on` in the environment' <(tr '\n' ' ' < "$STEP4")
check "skill says the daemon enforces the flag" 'The daemon enforces the same[[:space:]]+flag' <(tr '\n' ' ' < "$STEP4")

# ── /setup-browser-cookies ───────────────────────────────────────────────────
echo "setup-browser-cookies: no values, no default browser, honest states"
SC="$(render setup-browser-cookies)"
refute "no browser is hard-coded into an import command" 'cookie-import-browser[[:space:]]+(comet|chrome|arc|brave|edge|dia)' "$SC"
refute "no bash block dumps cookies or storage" '^\$B (cookies|storage)([[:space:]]|$)' <(fenced_bash "$SC")
check "forbids printing cookie values" 'never[[:space:]]+put a cookie value' <(tr '\n' ' ' < "$SC")
check "asks the user which browser" 'AskUserQuestion' "$SC"
refute "direct import does not cite a picker list it never saw" 'browsers the picker reported as detected' "$SC"
check "navigates to the domain before a direct import" '^\$B goto https://' <(fenced_bash "$SC")
for state in 'Not checked' 'Not verified' 'Verified'; do
  check "names the '$state' state" "\*\*$state\*\*" "$SC"
done
check "counts never prove login" 'never proves a login' "$SC"

# ── /browse ──────────────────────────────────────────────────────────────────
echo "browse: driving rules"
BR="$(render browse)"
RULES="$TMP/br-rules.md"
section "$BR" '^## Rules for driving the browser' '^## Core QA Patterns' > "$RULES"
[ -s "$RULES" ] || { echo "driving rules not found in browse" >&2; exit 1; }
check "invocation is consent to LOOK, not to ACT" 'consent to LOOK, not to ACT' "$RULES"
for host in '`localhost`' '`127.0.0.1`' '`::1`' '`.localhost`' '`.test`'; do
  check "LOCAL includes $host" "$(printf '%s' "$host" | sed 's/[.]/\\./g')" "$RULES"
done
check ".local is not LOCAL" '`\.local` *$|`\.local` host is NOT local' "$RULES"
check "NON-LOCAL mutations need one AskUserQuestion per run" 'AskUserQuestion ONCE per run' <(tr '\n' ' ' < "$RULES")
RULE4="$(tr '\n' ' ' < "$RULES" | grep -oE 'Never fetch, click, or follow a link whose path matches\*\*[^.]*' || true)"
[ -n "$RULE4" ] && ok "logout-link ban is a prohibition" || no "logout-link ban is a prohibition"
for word in logout signout delete remove cancel unsubscribe; do
  check "bans following $word links" "\`$word\`" <(printf '%s\n' "$RULE4")
done
check "never types real credentials" "Never type the user's passwords" "$RULES"
check "never prints session material" 'Never print session material' "$RULES"
check "js/eval output is unwrapped but untrusted" '`\$B js` and `\$B eval` output is NOT wrapped' "$RULES"
check "untrusted-content block covers js/eval" '^> 5\. `js` and `eval` output is NOT wrapped' "$BR"
refute "no QA example types a bare \"password\"" 'fill @e[0-9]+ "password"' "$BR"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
