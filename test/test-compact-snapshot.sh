#!/usr/bin/env bash
# bin/vibe-compact-snapshot — the Claude Code PreCompact hook. It writes the
# git state of the session's working directory to a per-project snapshot file
# and must never block compaction: stdout is always `{}` and the exit code 0.
# The transcript is referenced by path only; its contents never reach disk.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/vibe-compact-snapshot"
TMP="$(mktemp -d)"
export VIBESTACK_HOME="$TMP/home"
export HOME="$TMP/h"
export VIBESTACK_PROJECT_SLUG="snapshot-test"
mkdir -p "$VIBESTACK_HOME/bin" "$HOME"
cp "$ROOT/bin/vibe-slug" "$VIBESTACK_HOME/bin/vibe-slug"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
no()   { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
git init -q -b snap-branch "$REPO"
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m "first commit"

TRANSCRIPT="$TMP/transcript.jsonl"
printf '{"type":"user","message":"token SECRET-MARKER-9f3"}\n' > "$TRANSCRIPT"

SNAPS="$VIBESTACK_HOME/projects/snapshot-test/compact-snapshots"
count() { find "$SNAPS" -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }
payload() { # payload <cwd>
  printf '{"session_id":"sess-1","transcript_path":"%s","trigger":"manual","cwd":"%s","custom_instructions":""}' \
    "$TRANSCRIPT" "$1"
}

# (a) valid payload inside a git repo
out="$(payload "$REPO" | "$BIN")"; rc=$?
[ "$out" = "{}" ] && [ "$rc" -eq 0 ] && ok "valid payload prints {} and exits 0" || no "valid payload got '$out' rc=$rc"
[ "$(count)" = "1" ] && ok "one snapshot written" || no "expected 1 snapshot, got $(count)"
f="$(find "$SNAPS" -name '*.md' 2>/dev/null | head -1)"
grep -q 'snap-branch' "$f" 2>/dev/null && ok "snapshot names the branch" || no "branch missing from snapshot"
grep -qF "$TRANSCRIPT" "$f" 2>/dev/null && ok "snapshot records the transcript path" || no "transcript path missing"
grep -q 'first commit' "$f" 2>/dev/null && ok "snapshot carries the recent log" || no "git log missing"
if [ -n "$f" ] && ! grep -q 'SECRET-MARKER-9f3' "$f"; then ok "transcript contents never copied"; else no "transcript contents leaked into snapshot"; fi

# (b) malformed payload
rm -rf "$SNAPS"
out="$(printf 'not json' | "$BIN")"; rc=$?
[ "$out" = "{}" ] && [ "$rc" -eq 0 ] && ok "malformed payload prints {} and exits 0" || no "malformed payload got '$out' rc=$rc"
[ "$(count)" = "0" ] && ok "malformed payload writes nothing" || no "malformed payload wrote $(count) files"

# (c) off switch
out="$(payload "$REPO" | VIBESTACK_COMPACT_SNAPSHOT=0 "$BIN")"
[ "$out" = "{}" ] && [ "$(count)" = "0" ] && ok "VIBESTACK_COMPACT_SNAPSHOT=0 writes nothing" || no "off switch wrote $(count) files"

# (d) retention: 12 runs leave the 10 newest
for _ in $(seq 1 12); do payload "$REPO" | "$BIN" >/dev/null; done
[ "$(count)" = "10" ] && ok "retention keeps 10 snapshots" || no "expected 10 snapshots after 12 runs, got $(count)"

# (e) cwd outside any git repo still gets a snapshot
rm -rf "$SNAPS"
mkdir -p "$TMP/plain"
out="$(payload "$TMP/plain" | "$BIN")"
f="$(find "$SNAPS" -name '*.md' 2>/dev/null | head -1)"
[ "$out" = "{}" ] && [ -n "$f" ] && grep -q 'not a git repo' "$f" \
  && ok "non-repo cwd still writes a snapshot" || no "non-repo cwd snapshot missing or unmarked"

# (f) the command settings.json registers: a no-op exit 0 when the bin is not
# installed (a config-only install), a snapshot when it is
HOOK_CMD="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["PreCompact"][0]["hooks"][0]["command"])' "$ROOT/config/claude/settings.json")"
rm -rf "$SNAPS"
err="$(payload "$REPO" | VIBESTACK_HOME="$TMP/empty-home" sh -c "$HOOK_CMD" 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$err" ] && ok "registered hook is silent when the bin is missing" \
  || no "registered hook with no bin: rc=$rc stderr='$err'"
cp "$BIN" "$VIBESTACK_HOME/bin/vibe-compact-snapshot"
out="$(payload "$REPO" | sh -c "$HOOK_CMD")"
[ "$out" = "{}" ] && [ "$(count)" = "1" ] && ok "registered hook runs the installed bin" \
  || no "registered hook with bin: out='$out' snapshots=$(count)"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
