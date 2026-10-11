#!/usr/bin/env bash
# test-vibe-gc.sh — bin/vibe-gc audits the runtime configuration and soft-deletes
# only what it is told to, inside the roots it knows, with an undo path.
#
# Self-contained: HOME and VIBESTACK_HOME point into a temp dir, so the real
# ~/.claude is never read or written.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GC="$ROOT/bin/vibe-gc"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export VIBESTACK_HOME="$HOME/.vibestack"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

[ -x "$GC" ] || { echo "  FAIL bin/vibe-gc missing or not executable"; echo "vibe-gc: 0 passed, 1 failed"; exit 1; }

# ── fixtures ────────────────────────────────────────────────────────────────
C="$HOME/.claude"
mkdir -p "$C/skills/foo" "$C/skills/bar" "$C/hooks" "$C/file-history" "$C/projects" "$VIBESTACK_HOME"
printf 'bar\n' > "$C/skills/.vibestack-manifest"
printf -- '---\nname: bar\n---\nbody\n' > "$C/skills/bar/SKILL.md"
printf 'notes\n' > "$C/skills/foo/README.md"
printf '#!/bin/sh\n' > "$C/hooks/orphan.sh"
printf '#!/bin/sh\n. "$HOME/.claude/hooks/hook-lib.sh"\n' > "$C/hooks/used.sh"
printf '#!/bin/sh\n' > "$C/hooks/hook-lib.sh"
printf '#!/bin/sh\n' > "$C/hooks/status.sh"
cat > "$C/settings.json" <<'JSON'
{
  "statusLine": {"type": "command", "command": "sh ~/.claude/hooks/status.sh"},
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/used.sh"}]}]},
  "permissions": {"allow": ["Read", "Read", "Bash(*)", "Bash(git push:*)"]}
}
JSON
printf '{"mcpServers": {"demo-server": {"command": "demo"}}}\n' > "$HOME/.claude.json"
printf 'transcript\n' > "$C/projects/x.jsonl"
OLD="$C/file-history/old-entry"
printf 'snapshot\n' > "$OLD"
touch -t "$(python3 -I -c 'import datetime as d; print((d.datetime.now()-d.timedelta(days=45)).strftime("%Y%m%d%H%M"))')" "$OLD"

run_scan() { (cd "$TMP" && "$GC" scan "$@" 2>/dev/null); }

# ── scan ────────────────────────────────────────────────────────────────────
sleep 1
touch "$TMP/sentinel"
sleep 1
out="$(run_scan --days 30)"; rc=$?
[ "$rc" -eq 0 ] && ok "scan exits 0" || no "scan exit $rc"

rows=$(printf '%s\n' "$out" | grep -c . || true)
[ "$rows" -le 20 ] && ok "scan prints at most 20 rows" || no "scan printed $rows rows"
printf '%s\n' "$out" | awk -F'\t' 'NF!=7 {bad=1} END {exit bad}' \
  && ok "every row has 7 tab-separated columns" || no "malformed row in: $out"

printf '%s\n' "$out" | awk -F'\t' '$2=="skills" && $3 ~ /\/skills\/foo$/ && $7=="high"' | grep -q . \
  && ok "foo without SKILL.md is a high-confidence skills candidate" || no "foo not flagged high: $out"
printf '%s\n' "$out" | grep -q '/skills/bar' \
  && no "pack-owned bar listed as a candidate" || ok "pack-owned bar is never a candidate"
printf '%s\n' "$out" | awk -F'\t' '$2=="skills" && $4 ~ /usage: unmeasured/' | grep -q . \
  && ok "skill usage reported as unmeasured" || no "usage not reported unmeasured"

printf '%s\n' "$out" | awk -F'\t' '$2=="hooks" && $3 ~ /orphan\.sh$/ && $7=="high"' | grep -q . \
  && ok "orphan hook flagged high" || no "orphan.sh not flagged: $out"
printf '%s\n' "$out" | grep -q 'used\.sh' && no "referenced used.sh flagged" || ok "referenced hook not flagged"
printf '%s\n' "$out" | grep -q 'hook-lib\.sh' && no "helper sourced by a hook flagged" || ok "helper sourced by another hook not flagged"
printf '%s\n' "$out" | grep -q 'status\.sh' && no "statusLine script flagged" || ok "script referenced outside the hooks key not flagged"

printf '%s\n' "$out" | awk -F'\t' '$2=="permissions" && $4 ~ /duplicate/ && $4 ~ /Read/' | grep -q . \
  && ok "duplicate allow entry flagged" || no "duplicate permission not flagged: $out"
printf '%s\n' "$out" | awk -F'\t' '$2=="permissions" && $4 ~ /shadowed/ && index($4, "Bash(git push:*)")' | grep -q . \
  && ok "Bash(git push:*) shadowed by Bash(*) flagged" || no "shadowed permission not flagged: $out"

printf '%s\n' "$out" | awk -F'\t' '$2=="mcp" && index($4, "demo-server") && $4 ~ /configured/ && $4 ~ /evidence needed/' | grep -q . \
  && ok "MCP server reported configured / evidence needed" || no "mcp row missing: $out"

printf '%s\n' "$out" | awk -F'\t' '$2=="caches" && $3 ~ /file-history\/old-entry$/' | grep -q . \
  && ok "45-day-old cache entry is a candidate at --days 30" || no "old cache not flagged: $out"
out_long="$(run_scan --days 3650)"
printf '%s\n' "$out_long" | grep -q 'old-entry' \
  && no "old cache flagged at --days 3650" || ok "cache entry absent at --days 3650"

changed="$(find "$HOME" -newer "$TMP/sentinel" 2>/dev/null)"
[ -z "$changed" ] && ok "scan changes nothing on disk" || no "scan wrote: $changed"

# ── trash / log / undo ──────────────────────────────────────────────────────
TODAY="$(date +%Y-%m-%d)"
(cd "$TMP" && "$GC" trash "$C/skills/foo" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "trash foo exits 0" || no "trash foo exit $rc"
[ ! -e "$C/skills/foo" ] && [ -f "$VIBESTACK_HOME/gc-trash/$TODAY/skills/foo/README.md" ] \
  && ok "foo moved to gc-trash/<date>/skills/foo" || no "foo not moved into gc-trash"
grep -q "undo: mv '$VIBESTACK_HOME/gc-trash/$TODAY/skills/foo' '$C/skills/foo'" "$VIBESTACK_HOME/gc-log.md" 2>/dev/null \
  && ok "gc-log.md records an undo line" || no "no undo line in gc-log.md"
(cd "$TMP" && "$GC" log 2>/dev/null) | grep -q 'undo:' && ok "log prints the log" || no "log subcommand empty"

(cd "$TMP" && "$GC" undo "$TODAY" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$C/skills/foo/README.md" ] && [ ! -e "$VIBESTACK_HOME/gc-trash/$TODAY/skills/foo" ] \
  && ok "undo restores foo" || no "undo did not restore foo (exit $rc)"

refused() {
  local label="$1" target="$2"
  (cd "$TMP" && "$GC" trash "$target" >/dev/null 2>&1); local rc=$?
  if [ "$rc" -ne 0 ] && [ -e "$target" ]; then ok "refuses $label"; else no "$label not refused (exit $rc)"; fi
}
refused "~/.claude.json" "$HOME/.claude.json"
refused "a transcript under ~/.claude/projects" "$C/projects/x.jsonl"
refused "a manifest-claimed skill" "$C/skills/bar"
refused "a settings file" "$C/settings.json"
refused "a path outside the known roots" "$TMP/sentinel"

# trash judges paths against the default runtime roots only; --roots cannot widen it.
(cd "$TMP" && "$GC" trash --roots "$TMP" --days 1 "$TMP/sentinel" >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ -e "$TMP/sentinel" ] \
  && ok "trash ignores a widened --roots" || no "trash --roots moved a path outside the runtime roots (exit $rc)"

# One refused path in a batch moves nothing at all.
(cd "$TMP" && "$GC" trash "$C/hooks/orphan.sh" "$HOME/.claude.json" >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ -f "$C/hooks/orphan.sh" ] \
  && ok "a refused path in a batch moves nothing" || no "batch with a refused path moved files (exit $rc)"

echo "vibe-gc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
