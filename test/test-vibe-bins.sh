#!/usr/bin/env bash
# Smoke tests for the Phase-A vibe-* binaries. Self-contained: runs against an
# isolated VIBESTACK_HOME in a temp dir so it never touches real state.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
export VIBESTACK_HOME="$TMP/home"
mkdir -p "$VIBESTACK_HOME"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
no()   { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

# vibe-session-kind
out="$("$BIN/vibe-session-kind")"
[ "$out" = "interactive" ] && ok "session-kind defaults interactive" || no "session-kind got '$out'"
out="$(VIBESTACK_HEADLESS=1 "$BIN/vibe-session-kind")"
[ "$out" = "headless" ] && ok "session-kind headless via env" || no "session-kind headless got '$out'"

# vibe-repo-mode (source-able)
out="$("$BIN/vibe-repo-mode")"
echo "$out" | grep -qE '^REPO_MODE=(solo|collaborative)$' && ok "repo-mode emits REPO_MODE" || no "repo-mode got '$out'"

# vibe-telemetry-log off by default = no file
"$BIN/vibe-telemetry-log" --event-type t --skill x >/dev/null 2>&1
[ ! -f "$VIBESTACK_HOME/analytics/telemetry.jsonl" ] && ok "telemetry off by default (no write)" || no "telemetry wrote while off"
# enable -> writes
"$BIN/vibe-config" set telemetry on >/dev/null 2>&1
"$BIN/vibe-telemetry-log" --event-type run --skill ship --outcome ok >/dev/null 2>&1
[ -s "$VIBESTACK_HOME/analytics/telemetry.jsonl" ] && ok "telemetry writes when enabled" || no "telemetry did not write when on"

# vibe-timeline-log
"$BIN/vibe-timeline-log" '{"skill":"ship","event":"started"}' >/dev/null 2>&1
find "$VIBESTACK_HOME/projects" -name timeline.jsonl 2>/dev/null | grep -q . && ok "timeline appends" || no "timeline did not append"
"$BIN/vibe-timeline-log" 'not json' >/dev/null 2>&1 && ok "timeline survives bad json" || no "timeline errored on bad json"

# vibe-decision-log + search roundtrip
"$BIN/vibe-decision-log" '{"decision":"use memex as the brain","rationale":"single hosted source of truth","scope":"repo"}' >/dev/null 2>&1
id="$("$BIN/vibe-decision-search" --recent 5 | grep -oE 'd[0-9]+' | head -1)"
"$BIN/vibe-decision-search" | grep -q "use memex as the brain" && ok "decision logged + searchable" || no "decision not found"
# supersede drops it from the active set
"$BIN/vibe-decision-log" --supersede "$id" >/dev/null 2>&1
"$BIN/vibe-decision-search" | grep -q "use memex as the brain" && no "superseded decision still active" || ok "supersede removes from active"
# secret rejection
"$BIN/vibe-decision-log" '{"decision":"ship with key AKIAABCDEFGHIJKLMNOP"}' >/dev/null 2>&1 && no "secret decision was accepted" || ok "secret decision rejected"

# vibe-update-check never errors
"$BIN/vibe-update-check" >/dev/null 2>&1; [ $? -le 1 ] && ok "update-check exits cleanly" || no "update-check crashed"

# vibe-design: detect-and-use on OPENAI_API_KEY; graceful on unsupported verbs
[ "$(env -u OPENAI_API_KEY "$BIN/vibe-design" status)" = "DESIGN_NOT_AVAILABLE" ] \
  && ok "design unavailable without key" || no "design status wrong without key"
[ "$(OPENAI_API_KEY=dummy "$BIN/vibe-design" status)" = "DESIGN_AVAILABLE" ] \
  && ok "design available with key" || no "design status wrong with key"
"$BIN/vibe-design" compare >/dev/null 2>&1 && ok "design skips unsupported verb" || no "design crashed on compare"

# vibestack umbrella CLI
out="$("$BIN/vibestack" version)"
grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$out" && ok "vibestack version prints semver" || no "vibestack version got '$out'"
"$BIN/vibestack" help >/dev/null 2>&1 && ok "vibestack help exits 0" || no "vibestack help failed"
out="$("$BIN/vibestack" session-kind)"
[ "$out" = "interactive" ] && ok "vibestack dispatches to vibe-session-kind" || no "vibestack dispatch got '$out'"
"$BIN/vibestack" no-such-tool >/dev/null 2>&1 && no "vibestack accepted unknown command" || ok "vibestack rejects unknown command"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
