#!/usr/bin/env bash
# test-vibe-upgrade-flow.sh — runs the bash blocks of skills/vibe-upgrade/SKILL.md
# against a local fake remote in an isolated HOME.
#
# Covers: Step 3.5 replays the original install (a Claude-only install stays
# Claude-only, never `--yes`) and stops when no manifest says what was
# installed; Step 4 stops on a failed fetch before anything runs, rolls a failed
# auto-upgrade back with `git reset --keep` so uncommitted work survives, and
# says RESTORED only when the old version re-installed; the vendored swap refuses
# a stale `.bak` and never loses the live copy; Step 4.5 refuses a stale `.bak`.
#
# Usage: test/test-vibe-upgrade-flow.sh [path/to/vibe-upgrade/SKILL.md]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${1:-$ROOT/skills/vibe-upgrade/SKILL.md}"
[ -f "$SKILL" ] || { echo "no such file: $SKILL" >&2; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unset VIBESTACK_HOME XDG_STATE_HOME CODEX_HOME VIBESTACK_AUTO_UPGRADE

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# X "<heading substring>" [n] -> the n-th ```bash block of that section.
# A section ends at the next `## ` or `### ` heading.
X() {
  python3 -I - "$SKILL" "$@" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
head = sys.argv[2]
idx = int(sys.argv[3]) if len(sys.argv) > 3 else 0
start = text.find(head)
if start < 0:
    sys.exit("heading not found: " + head)
sec = text[start:]
m = re.search(r"\n#{2,3} ", sec[3:])
sec = sec[:m.start() + 3] if m else sec
blocks = re.findall(r"```bash\n(.*?)```", sec, re.S)
if idx >= len(blocks):
    sys.exit("no bash block %d under %s" % (idx, head))
sys.stdout.write(blocks[idx])
PY
}

# fill NAME=value ... — stdin with each '<NAME>' placeholder replaced by the
# single-quoted value, the way the agent fills it in before running the block.
fill() {
  python3 -I -c '
import sys
s = sys.stdin.read()
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    s = s.replace("\x27<%s>\x27" % k, "\x27%s\x27" % v.replace("\x27", "\x27\\\x27\x27"))
sys.stdout.write(s)
' "$@"
}

G="git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c commit.gpgsign=false"
T=""; H=""

setup() {
  T="$(mktemp -d "$WORK/case.XXXXXX")"; H="$T/home"; mkdir -p "$H/.vibestack/bin"
  $G init -q --bare "$T/remote.git"; git -C "$T/remote.git" symbolic-ref HEAD refs/heads/main
  $G init -q "$T/seed"
  echo 1.0.0 > "$T/seed/VERSION"
  mkdir -p "$T/seed/skills/careful/bin"; : > "$T/seed/skills/careful/bin/x"
  # Fake install: records its argv; fails when the checkout carries FAIL, or
  # always when $HOME/ALWAYS_FAIL exists (so the old version fails too).
  cat > "$T/seed/install" <<'IN'
#!/usr/bin/env bash
echo "$*" >> "$HOME/install-calls"
[ -f "$(dirname "$0")/FAIL" ] && exit 1
[ -f "$HOME/ALWAYS_FAIL" ] && exit 1
exit 0
IN
  chmod +x "$T/seed/install"
  $G -C "$T/seed" add -A; $G -C "$T/seed" commit -qm v1
  git -C "$T/seed" push -q "$T/remote.git" main
  git clone -q "$T/remote.git" "$T/co"
}
bump() {
  echo 2.0.0 > "$T/seed/VERSION"
  [ "${1:-}" = fail ] && : > "$T/seed/FAIL"
  $G -C "$T/seed" add -A; $G -C "$T/seed" commit -qm v2
  git -C "$T/seed" push -q "$T/remote.git" main
}
replay_block() { HOME="$H" bash -c "$(X '### Step 3.5' | fill REPO="$1" _ROOT=)"; }
prep_replay() { mkdir -p "$H/.claude/skills"; : > "$H/.claude/skills/.vibestack-manifest"; replay_block "$T/co" >/dev/null; }
git_block() {
  HOME="$H" VIBESTACK_AUTO_UPGRADE="${AUTO:-}" \
    bash -c "$(X '### Step 4: Upgrade the primary' 0 | fill REPO="$T/co" REPLAY="$H/.vibestack/upgrade-replay.sh")"
}
vend_block() {
  HOME="$H" bash -c "$(X '### Step 4: Upgrade the primary' 1 | fill REPO="$1" REPLAY="$H/.vibestack/upgrade-replay.sh" \
    | sed "s#https://github.com/timurgaleev/vibestack.git#$T/remote.git#")"
}
sync_block() { HOME="$H" bash -c "$(X '### Step 4.5' 1 | fill REPO="$T/co" LOCAL_VIBESTACK="$T/proj/vs")"; }
mkvend() { mkdir -p "$T/proj"; cp -R "$T/co" "$T/proj/vs"; rm -rf "$T/proj/vs/.git"; echo local > "$T/proj/vs/MARK"; }

echo "Step 3.5: replay the original install"
setup; mkdir -p "$H/.claude/skills"; : > "$H/.claude/skills/.vibestack-manifest"
out="$(replay_block "$T/co" 2>&1)"; rc=$?
R="$H/.vibestack/upgrade-replay.sh"
if [ $rc -eq 0 ] && grep -q -- "--only=skills --target=claude || exit 1" "$R" 2>/dev/null \
   && ! grep -qE -- "--yes|cursor|kiro|codex|--only=config" "$R"; then
  ok "a Claude-only install replays --target=claude only"
else
  no "replay: rc=$rc '$out'"
fi
mkdir -p "$H/.local/state/vibekit"; : > "$H/.local/state/vibekit/manifest_claude"
replay_block "$T/co" >/dev/null 2>&1
grep -q -- "--only=config --target=claude" "$R" 2>/dev/null && ok "a config manifest adds a config replay" \
                                                        || no "no config replay for a config manifest"
# RTK follows the first install, never PATH: an rtk binary on PATH must not
# re-enable it for a config installed with --no-rtk, and its hook keeps it on.
mkdir -p "$T/rtkbin"; printf '#!/bin/sh\n' > "$T/rtkbin/rtk"; chmod +x "$T/rtkbin/rtk"
mkdir -p "$H/.claude"; echo '{}' > "$H/.claude/settings.json"
PATH="$T/rtkbin:$PATH" replay_block "$T/co" >/dev/null 2>&1
grep -q -- "--only=config.*--no-rtk" "$R" 2>/dev/null && ok "rtk on PATH does not override an install without RTK" \
                                                     || no "replay re-enables RTK because rtk is on PATH"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"rtk hook"}]}]}}' > "$H/.claude/settings.json"
replay_block "$T/co" >/dev/null 2>&1
grep -q -- "--only=config" "$R" && ! grep -q -- "--no-rtk" "$R" && ok "an installed RTK hook keeps RTK in the replay" \
                                                              || no "RTK hook present but replay passes --no-rtk"
rm -f "$H/.claude/settings.json"

setup; out="$(replay_block "$T/co" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && case "$out" in REPLAY_UNKNOWN*) true ;; *) false ;; esac; then
  ok "no manifest -> REPLAY_UNKNOWN, non-zero exit"
else
  no "no manifest: rc=$rc '$out'"
fi

echo "Step 4, git checkout"
setup; prep_replay; git -C "$T/co" remote set-url origin "$T/missing.git"
out="$(git_block 2>/dev/null)"; rc=$?
if [ $rc -ne 0 ] && case "$out" in FETCH_FAILED*) true ;; *) false ;; esac; then
  ok "failed fetch -> FETCH_FAILED, non-zero exit"
else
  no "failed fetch: rc=$rc '$out'"
fi
[ ! -f "$H/install-calls" ] && ok "no install ran after a failed fetch" || no "install ran after a failed fetch"

setup; prep_replay; bump
out="$(git_block 2>/dev/null)"; rc=$?
if [ $rc -eq 0 ] && case "$out" in "INSTALL_OK 2.0.0"*) true ;; *) false ;; esac; then
  ok "success -> INSTALL_OK"
else
  no "success: rc=$rc '$out'"
fi
[ "$(cat "$H/install-calls" 2>/dev/null)" = "--only=skills --target=claude" ] \
  && ok "install argv is the replay, not --yes" || no "install argv: $(cat "$H/install-calls" 2>/dev/null)"

setup; prep_replay; PREV="$(git -C "$T/co" rev-parse HEAD)"; bump fail
echo "my work" > "$T/co/notes.txt"                 # untracked
echo "tweak" >> "$T/co/skills/careful/bin/x"       # tracked, uncommitted, untouched by v2
out="$(AUTO=1 git_block 2>/dev/null)"; rc=$?
[ "$(git -C "$T/co" rev-parse HEAD)" = "$PREV" ] && ok "auto mode: failed install moves back to the original SHA" \
                                                 || no "auto mode: HEAD not restored"
[ -f "$T/co/notes.txt" ] && grep -q tweak "$T/co/skills/careful/bin/x" \
  && ok "auto mode: uncommitted work survives the rollback" || no "auto mode: local edits lost"
if [ $rc -ne 0 ] && case "$out" in RESTORED*) true ;; *) false ;; esac; then
  ok "auto mode: RESTORED, non-zero exit"
else
  no "auto mode rollback: rc=$rc '$out'"
fi

setup; prep_replay; PREV="$(git -C "$T/co" rev-parse HEAD)"; bump; : > "$H/ALWAYS_FAIL"
out="$(AUTO=1 git_block 2>/dev/null)"; rc=$?
if [ $rc -ne 0 ] && grep -q "^RESTORE_FAILED" <<<"$out" && ! grep -q "^RESTORED" <<<"$out"; then
  ok "auto mode, old version also fails -> RESTORE_FAILED, never RESTORED"
else
  no "auto mode, both fail: rc=$rc '$out'"
fi
[ "$(git -C "$T/co" rev-parse HEAD)" = "$PREV" ] && ok "auto mode, both fail: checkout still back at the original SHA" \
                                                 || no "auto mode, both fail: HEAD not restored"

setup; prep_replay; PREV="$(git -C "$T/co" rev-parse HEAD)"; bump fail
out="$(git_block 2>/dev/null)"; rc=$?
if [ $rc -ne 0 ] && grep -q "INSTALL_FAILED" <<<"$out" && grep -q "$PREV" <<<"$out"; then
  ok "interactive: INSTALL_FAILED names the previous SHA, no reset"
else
  no "interactive failed install: rc=$rc '$out'"
fi

echo "Step 4, vendored copy"
setup; prep_replay; mkvend; mkdir "$T/proj/vs.bak"; : > "$T/proj/vs.bak/old"
out="$(vend_block "$T/proj/vs" 2>/dev/null)"; rc=$?
if [ $rc -ne 0 ] && case "$out" in STALE_BACKUP*) true ;; *) false ;; esac; then
  ok "stale .bak -> STALE_BACKUP"
else
  no "stale .bak: rc=$rc '$out'"
fi
[ -f "$T/proj/vs/MARK" ] && [ -f "$T/proj/vs.bak/old" ] && [ ! -e "$T/proj/vs.bak/vs" ] \
  && ok "stale .bak: live install neither nested nor moved" || no "stale .bak: live install disturbed"

setup; prep_replay; bump fail; mkvend
out="$(vend_block "$T/proj/vs" 2>/dev/null)"; rc=$?
[ -f "$T/proj/vs/MARK" ] && [ ! -e "$T/proj/vs.bak" ] && ok "failed install: previous copy back in place" \
                                                     || no "failed install: previous copy missing"
if [ $rc -ne 0 ] && case "$out" in RESTORED*) true ;; *) false ;; esac; then
  ok "failed install: RESTORED, non-zero exit"
else
  no "failed install: rc=$rc '$out'"
fi
debris="$(ls -A "$T/proj" | grep -v '^vs$' || true)"
[ -z "$debris" ] && ok "failed install: no staging debris" || no "failed install left: $debris"

setup; prep_replay; bump; mkvend; : > "$H/ALWAYS_FAIL"
out="$(vend_block "$T/proj/vs" 2>/dev/null)"; rc=$?
if [ $rc -ne 0 ] && grep -q "^RESTORE_FAILED" <<<"$out" && ! grep -q "^RESTORED" <<<"$out"; then
  ok "old version also fails -> RESTORE_FAILED, never RESTORED"
else
  no "vendored, both fail: rc=$rc '$out'"
fi
[ -f "$T/proj/vs/MARK" ] && ok "old version also fails: previous copy back in place" \
                         || no "old version also fails: previous copy missing"

setup; prep_replay; bump; mkvend
out="$(vend_block "$T/proj/vs" 2>/dev/null)"; rc=$?
if [ $rc -eq 0 ] && case "$out" in "VENDORED_UPGRADE_OK 2.0.0"*) true ;; *) false ;; esac && [ ! -e "$T/proj/vs.bak" ]; then
  ok "success -> VENDORED_UPGRADE_OK, backup removed"
else
  no "vendored success: rc=$rc '$out'"
fi

echo "Step 4.5, vendored sync"
setup; mkvend; mkdir "$T/proj/vs.bak"
out="$(sync_block 2>/dev/null)"; rc=$?
if [ $rc -ne 0 ] && grep -q SYNC_SKIPPED <<<"$out" && [ -f "$T/proj/vs/MARK" ]; then
  ok "stale .bak -> SYNC_SKIPPED, copy untouched"
else
  no "sync over stale .bak: rc=$rc '$out'"
fi
rm -rf "$T/proj/vs.bak"
out="$(sync_block 2>/dev/null)"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = SYNC_OK ] && [ ! -e "$T/proj/vs/MARK" ] && [ ! -e "$T/proj/vs/.git" ] \
   && [ -f "$T/proj/vs/install" ]; then
  ok "sync replaces the copy without .git"
else
  no "sync: rc=$rc '$out'"
fi

echo
echo "vibe-upgrade flow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
