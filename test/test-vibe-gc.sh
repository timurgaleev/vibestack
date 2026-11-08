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

# Copilot's skills root is a default root too, at $COPILOT_HOME/skills.
CP="$HOME/.copilot/skills"
mkdir -p "$CP/pack" "$CP/stray"
printf 'pack\n' > "$CP/.vibestack-manifest"
printf -- '---\nname: pack\n---\nbody\n' > "$CP/pack/SKILL.md"
printf 'notes\n' > "$CP/stray/README.md"
out3="$(env -u COPILOT_HOME "$GC" scan --days 30 2>/dev/null)"
printf '%s\n' "$out3" | awk -F'\t' '$2=="skills" && $3 ~ /\/\.copilot\/skills\/stray$/' | grep -q . \
  && ok "a stray directory in ~/.copilot/skills is a skills candidate" || no "copilot root not scanned: $out3"
ALT="$TMP/alt-copilot"
mkdir -p "$ALT/skills/elsewhere"
printf 'notes\n' > "$ALT/skills/elsewhere/README.md"
out3="$(COPILOT_HOME="$ALT" "$GC" scan --days 30 2>/dev/null)"
printf '%s\n' "$out3" | awk -F'\t' '$2=="skills" && $3 ~ /\/alt-copilot\/skills\/elsewhere$/' | grep -q . \
  && ok "the copilot root follows \$COPILOT_HOME" || no "\$COPILOT_HOME root not scanned: $out3"

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

# ── repo-local state: browse logs under <toplevel>/.vibestack ───────────────
export HOME="$TMP/home3"
export VIBESTACK_HOME="$HOME/.vibestack"
mkdir -p "$HOME"
REPO="$TMP/repo"
RS="$REPO/.vibestack"
mkdir -p "$RS/qa-reports" "$RS/chromium-profile" "$REPO/sub"
git -C "$REPO" init -q
# 1.5 MB of numbered JSONL records: a trim must keep whole records only.
python3 -I -c '
import sys
with open(sys.argv[1], "w") as f:
    for i in range(1, 20001):
        f.write("{\"n\": %d, \"pad\": \"%s\"}\n" % (i, "x" * 60))' "$RS/browse-audit.jsonl"
chmod 640 "$RS/browse-audit.jsonl"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("line\n" * 40000)' "$RS/browse-console.log"   # 200 KB
python3 -I -c 'import sys; open(sys.argv[1], "w").write("c" * 2000000)' "$RS/cookies.json"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("r" * 2000000)' "$RS/qa-reports/report.log"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("p" * 2000000)' "$RS/chromium-profile/Cookies.log"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("s\n" * 1000000)' "$TMP/elsewhere.log"
ln -s "$TMP/elsewhere.log" "$RS/browse-linked.log"
audit_size=$(wc -c < "$RS/browse-audit.jsonl" | tr -d ' ')
audit_last=$(tail -n 1 "$RS/browse-audit.jsonl")

touch "$TMP/sentinel3"; sleep 1
out4="$(cd "$REPO/sub" && "$GC" scan --days 30 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && ok "scan from inside a repo exits 0" || no "repo scan exit $rc"
printf '%s\n' "$out4" | awk -F'\t' '$2=="repo" && $3 ~ /\/\.vibestack\/browse-audit\.jsonl$/ && $5 >= 1024' | grep -q . \
  && ok "a repo .vibestack log over 1 MB is a repo candidate" || no "browse-audit.jsonl not reported: $out4"
printf '%s\n' "$out4" | grep -q 'browse-console\.log' \
  && no "a log under 1 MB reported: $out4" || ok "a log under 1 MB is not reported"
printf '%s\n' "$out4" | grep -qE 'cookies\.json|qa-reports|chromium-profile' \
  && no "cookies, reports or profile reported: $out4" || ok "cookies, reports and the profile are never candidates"
printf '%s\n' "$out4" | grep -q 'browse-linked\.log' \
  && no "a symlinked log reported: $out4" || ok "a symlinked log is not reported"
changed="$(find "$REPO" -newer "$TMP/sentinel3" 2>/dev/null | grep -v '/\.git/')"
[ -z "$changed" ] && ok "repo scan changes nothing on disk" || no "repo scan wrote: $changed"

trim_refused() {
  local label="$1" target="$2" before
  before=$(wc -c < "$target" | tr -d ' ')
  (cd "$REPO" && "$GC" trim "$target" >/dev/null 2>&1); local rc=$?
  if [ "$rc" -ne 0 ] && [ "$(wc -c < "$target" | tr -d ' ')" = "$before" ]; then ok "trim refuses $label"
  else no "trim did not refuse $label (exit $rc)"; fi
}
trim_refused "cookies" "$RS/cookies.json"
trim_refused "a report" "$RS/qa-reports/report.log"
trim_refused "a file in the browser profile" "$RS/chromium-profile/Cookies.log"
trim_refused "a log under 1 MB" "$RS/browse-console.log"
trim_refused "a symlinked log" "$RS/browse-linked.log"
trim_refused "a log outside the repo's .vibestack" "$TMP/elsewhere.log"

# A running browse daemon is still appending; trimming under it loses records.
sleep 300 & live=$!
printf '{"pid": %d, "port": 1}\n' "$live" > "$RS/browse.json"
out5="$(cd "$REPO" && "$GC" scan --days 30 2>/dev/null)"
printf '%s\n' "$out5" | awk -F'\t' '$2=="repo" && $4 ~ /browse daemon running/' | grep -q . \
  && ok "scan says the browse daemon is running" || no "running daemon not reported: $out5"
trim_refused "a log while the browse daemon runs" "$RS/browse-audit.jsonl"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
printf 'not json' > "$RS/browse.json"
trim_refused "a log when the daemon state is unreadable" "$RS/browse-audit.jsonl"
sh -c 'exit 0' & dead=$!; wait "$dead"
printf '{"pid": %d, "port": 1}\n' "$dead" > "$RS/browse.json"

(cd "$REPO/sub" && "$GC" trim "$RS/browse-audit.jsonl" >/dev/null 2>&1); rc=$?
new_size=$(wc -c < "$RS/browse-audit.jsonl" | tr -d ' ')
[ "$rc" -eq 0 ] && [ "$new_size" -le 262144 ] && [ "$new_size" -gt 200000 ] \
  && ok "trim keeps at most the last 256 KB (exit $rc, $new_size B)" || no "trim exit $rc, size $new_size"
head -n 1 "$RS/browse-audit.jsonl" | python3 -I -c 'import json, sys; json.loads(sys.stdin.readline())' 2>/dev/null \
  && ok "the trimmed log starts on a whole record" || no "first line after trim is a partial record"
[ "$(tail -n 1 "$RS/browse-audit.jsonl")" = "$audit_last" ] \
  && ok "the newest record survives the trim" || no "last record changed by trim"
mode=$(python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$RS/browse-audit.jsonl")
[ "$mode" = "0o640" ] && ok "trim keeps the log's mode" || no "mode after trim: $mode"
kept="$VIBESTACK_HOME/gc-trash/$TODAY/repo/browse-audit.jsonl"
[ -f "$kept" ] && [ "$(wc -c < "$kept" | tr -d ' ')" = "$audit_size" ] \
  && ok "the untrimmed original is kept in gc-trash/<date>/repo" || no "original not kept at $kept"
grep -q "trimmed '$RS/browse-audit.jsonl'" "$VIBESTACK_HOME/gc-log.md" 2>/dev/null \
  && ok "gc-log.md records the trim" || no "no trim line in gc-log.md"
# Value: protects=undo puts a trimmed log's original back with the records
# appended since the trim; fails_when=undo skips trim lines (the original stays
# in the trash) or overwrites the appended records; why_new=no row ran undo
# after a trim; seam=none
printf '{"n": "after-trim"}\n' >> "$RS/browse-audit.jsonl"
(cd "$REPO" && "$GC" undo "$TODAY" >/dev/null 2>&1); rc=$?
undo_size=$(wc -c < "$RS/browse-audit.jsonl" | tr -d ' ')
[ "$rc" -eq 0 ] && [ "$undo_size" -eq $((audit_size + 20)) ] \
  && [ "$(head -n 1 "$RS/browse-audit.jsonl" | cut -c1-8)" = '{"n": 1,' ] \
  && [ "$(tail -n 1 "$RS/browse-audit.jsonl")" = '{"n": "after-trim"}' ] \
  && ok "undo restores a trimmed log's original and keeps the records appended since" \
  || no "undo after a trim: exit $rc, size $undo_size (want $((audit_size + 20)))"
[ ! -e "$kept" ] && ok "undo takes the kept original out of the trash" || no "kept original still in the trash after undo"
grep -q "restored '$RS/browse-audit.jsonl'" "$VIBESTACK_HOME/gc-log.md" 2>/dev/null \
  && ok "gc-log.md records the restore" || no "no restore line for the trim"
(cd "$REPO" && "$GC" undo "$TODAY" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -c < "$RS/browse-audit.jsonl" | tr -d ' ')" -eq "$undo_size" ] \
  && ok "a second undo of the same day changes nothing" || no "second undo: exit $rc"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("net\n" * 300000)' "$RS/browse-network.log"
(cd "$REPO" && "$GC" trim "$RS/browse-network.log" "$RS/../.vibestack/browse-network.log" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -c < "$RS/browse-network.log" | tr -d ' ')" -le 262144 ] \
  && [ ! -e "$VIBESTACK_HOME/gc-trash/$TODAY/repo/browse-network.log.1" ] \
  && ok "the same log named twice is trimmed once" || no "duplicate trim path: exit $rc"

# Value: protects=trim is all-or-nothing, one refused path leaves every log untouched; fails_when=trim validates and cuts per path (a good log is trimmed before the refused one is seen); why_new=trim_refused passes one path at a time, so mixed batches are never exercised; seam=none
python3 -I -c 'import sys; open(sys.argv[1], "w").write("m\n" * 800000)' "$RS/browse-mixed.log"
mixed_size=$(wc -c < "$RS/browse-mixed.log" | tr -d ' ')
(cd "$REPO" && "$GC" trim "$RS/browse-mixed.log" "$RS/cookies.json" >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ "$(wc -c < "$RS/browse-mixed.log" | tr -d ' ')" = "$mixed_size" ] \
  && [ ! -e "$VIBESTACK_HOME/gc-trash/$TODAY/repo/browse-mixed.log" ] \
  && ok "one refused path in a batch leaves the good log untrimmed" || no "mixed batch: exit $rc, partial trim"

# Value: protects=trim only acts inside a repository's .vibestack; fails_when=the repo lookup is dropped or falls back to the cwd so a log is trimmed from a non-repo directory; why_new=every trim row runs with cwd inside $REPO; seam=none
mkdir -p "$TMP/norepo"
(cd "$TMP/norepo" && "$GC" trim "$RS/browse-mixed.log" >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ "$(wc -c < "$RS/browse-mixed.log" | tr -d ' ')" = "$mixed_size" ] \
  && ok "trim from a directory outside any repository refuses" || no "trim outside a repo: exit $rc"

# The scan row's path is pasted into a quoted trim command, and a repository
# names its own files: a name outside [A-Za-z0-9._-] is never offered or trimmed.
BADLOG="$RS/"'bad$(id).log'
python3 -I -c 'import sys; open(sys.argv[1], "w").write("b\n" * 1000000)' "$BADLOG"
printf '%s\n' "$(cd "$REPO" && "$GC" scan --days 30 2>/dev/null)" | grep -qF 'bad$(id)' \
  && no "scan offered a log with shell characters in its name" || ok "scan never offers a log with shell characters in its name"
trim_refused "a log with shell characters in its name" "$BADLOG"
rm -f "$BADLOG"
# One record longer than the window: cutting at a line break would keep nothing.
python3 -I -c 'import sys; open(sys.argv[1], "w").write("{\"blob\": \"" + "z" * 1500000 + "\"}")' "$RS/browse-oneline.jsonl"
trim_refused "a log with no line break in its last 256 KB" "$RS/browse-oneline.jsonl"
# The same record ending in a newline: the only break is the last byte.
printf '\n' >> "$RS/browse-oneline.jsonl"
trim_refused "a log whose only break in the window is its last byte" "$RS/browse-oneline.jsonl"

echo "vibe-gc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
