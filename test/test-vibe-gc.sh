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

# ── a second machine: partial usage, install leftovers, hook-dir noise ────
export HOME="$TMP/home2"
export VIBESTACK_HOME="$HOME/.vibestack"
C2="$HOME/.claude"
mkdir -p "$C2/skills/a" "$C2/skills/b" "$C2/hooks/__pycache__" "$C2/hooks/.git/objects/ab" \
  "$VIBESTACK_HOME/analytics" "$C2/skills.old/foreign" "$C2/skills.staging.failed.123/x"
printf -- '---\nname: a\n---\nbody\n' > "$C2/skills/a/SKILL.md"
printf -- '---\nname: b\n---\nbody\n' > "$C2/skills/b/SKILL.md"
# Analytics saw `a` typed, but there are no transcripts, so nobody measured
# whether the model invoked `b`.
python3 -I -c 'import datetime as d, json; print(json.dumps({"skill": "a", "ts": d.datetime.now(d.timezone.utc).isoformat()}))' \
  > "$VIBESTACK_HOME/analytics/skill-usage.jsonl"
printf '#!/usr/bin/env python3\n' > "$C2/hooks/h.py"
printf 'bytecode\n' > "$C2/hooks/__pycache__/h.cpython-312.pyc"
printf 'object\n' > "$C2/hooks/.git/objects/ab/cdef"
printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/h.py"}]}]}}\n' > "$C2/settings.json"
printf 'leftover\n' > "$C2/skills.old/foreign/SKILL.md"
printf 'leftover\n' > "$C2/skills.staging.failed.123/x/SKILL.md"
old_ts="$(python3 -I -c 'import datetime as d; print((d.datetime.now()-d.timedelta(days=45)).strftime("%Y%m%d%H%M"))')"
find "$C2/skills.old" "$C2/skills.staging.failed.123" -exec touch -t "$old_ts" {} +

out2="$(run_scan --days 30)"
printf '%s\n' "$out2" | grep -q '/skills/b.*usage: none' \
  && no "usage counted as measured with no transcripts read: $out2" || ok "no transcripts read leaves model usage unmeasured"
printf '%s\n' "$out2" | awk -F'\t' '$2=="caches" && $3 ~ /\/\.claude\/skills\.old$/' | grep -q . \
  && ok "install leftover skills.old beside a root is a caches candidate" || no "skills.old not flagged: $out2"
printf '%s\n' "$out2" | awk -F'\t' '$2=="caches" && $3 ~ /\/\.claude\/skills\.staging\.failed\.123$/' | grep -q . \
  && ok "install leftover skills.staging.* is a caches candidate" || no "skills.staging.* not flagged: $out2"
printf '%s\n' "$out2" | grep -qE '__pycache__|/\.git/' \
  && no "generated or VCS files listed as orphan hooks: $out2" || ok "hook scan skips __pycache__ and .git"
(cd "$TMP" && "$GC" trash "$C2/skills.old" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$C2/skills.old" ] && [ -d "$VIBESTACK_HOME/gc-trash/$TODAY/caches/skills.old" ] \
  && ok "trash moves an install leftover beside a root" || no "skills.old not trashed (exit $rc)"
mkdir -p "$C2/skills-notes"
refused "a sibling of a root that is not an install leftover" "$C2/skills-notes"

# The skill's permission-removal block rewrites settings through a temp file;
# the rename must not widen a 0600 settings file to the umask default.
SET="$TMP/perm-settings.json"
printf '{"permissions":{"allow":["Bash(ls:*)","WebFetch"]}}\n' > "$SET"; chmod 600 "$SET"
printf 'WebFetch' > "$VIBESTACK_HOME/gc-entry.txt"
python3 -I - "$ROOT/skills/vibe-gc/SKILL.md" "$SET" > "$TMP/perm-block.sh" <<'PY'
import sys
s, settings = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
i = s.index("_SETTINGS='<settings file path from the row>'")
end = 'echo "REMOVED_FROM: $_SETTINGS"'
j = s.index(end, i) + len(end)
print(s[i:j].replace("<settings file path from the row>", settings))
PY
(umask 022; bash "$TMP/perm-block.sh" >/dev/null 2>&1)
mode=$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$SET")
[ "$mode" = "0o600" ] && ! grep -q WebFetch "$SET" \
  && ok "permission removal keeps a 0600 settings file at 0600" || no "settings mode after removal: $mode"

echo "vibe-gc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
