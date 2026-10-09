#!/usr/bin/env bash
# test-vibe-upgrade-guards.sh — the mutating blocks of skills/vibe-upgrade/SKILL.md
# refuse to run on an empty or wrong install dir, and migrations receive the
# install dir.
#
# Each block runs in a fresh shell, the way an agent runs it, so a variable the
# agent forgot to carry over arrives empty. These cases check that an empty
# REPO / REPLAY / _ROOT / OLD_VERSION stops the block before any git, mv, cp or
# rm, and that Step 4.75 hands VIBESTACK_INSTALL_DIR to each migration.
#
# Usage: test/test-vibe-upgrade-guards.sh [path/to/vibe-upgrade/SKILL.md]
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
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

# X "<heading substring>" [n] -> the n-th ```bash block of that section.
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

# make_pack DIR — a minimal vibestack-shaped directory whose install logs calls.
make_pack() {
  mkdir -p "$1/skills"
  echo 1.0.0 > "$1/VERSION"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/install-calls"\n' "$WORK" > "$1/install"
  chmod +x "$1/install"
}

GIT_BLOCK="$(X '### Step 4: Upgrade the primary' 0)" || exit 2
VEND_BLOCK="$(X '### Step 4: Upgrade the primary' 1)" || exit 2
TEAM_BLOCK="$(X '### Step 4.5' 0)" || exit 2
SYNC_BLOCK="$(X '### Step 4.5' 1)" || exit 2
MIG_BLOCK="$(X '### Step 4.75')" || exit 2

H="$WORK/home"; mkdir -p "$H/.vibestack"
REPLAY_FILE="$H/.vibestack/upgrade-replay.sh"
printf '#!/usr/bin/env bash\ncd "$1" || exit 1\n./install --only=skills --target=claude\n' > "$REPLAY_FILE"

run() { (cd "$WORK" && HOME="$H" bash -c "$1" 2>&1); }

echo "Step 4, git checkout"
out="$(run "$(fill REPO= REPLAY="$REPLAY_FILE" <<<"$GIT_BLOCK")")"; rc=$?
check "empty REPO -> NOT_A_VIBESTACK_INSTALL, non-zero" '[ $rc -ne 0 ] && grep -q NOT_A_VIBESTACK_INSTALL <<<"$out"'
check "empty REPO: no git ran in the caller's directory" '! grep -q FETCH_FAILED <<<"$out"'
out="$(run "$GIT_BLOCK")"; rc=$?
check "unfilled <REPO> placeholder -> NOT_A_VIBESTACK_INSTALL" '[ $rc -ne 0 ] && grep -q NOT_A_VIBESTACK_INSTALL <<<"$out"'

$G init -q "$WORK/outer"; make_pack "$WORK/outer/sub"
$G -C "$WORK/outer" add -A; $G -C "$WORK/outer" commit -qm init
out="$(run "$(fill REPO="$WORK/outer/sub" REPLAY="$REPLAY_FILE" <<<"$GIT_BLOCK")")"; rc=$?
check "REPO inside another repo -> NOT_A_VIBESTACK_INSTALL" '[ $rc -ne 0 ] && grep -q "not the top of its own git checkout" <<<"$out"'
check "REPO inside another repo: install never ran" '[ ! -f "$WORK/install-calls" ]'

$G init -q "$WORK/co"; make_pack "$WORK/co"
$G -C "$WORK/co" add -A; $G -C "$WORK/co" commit -qm init
out="$(run "$(fill REPO="$WORK/co" REPLAY= <<<"$GIT_BLOCK")")"; rc=$?
check "empty REPLAY -> REPLAY_UNKNOWN before any fetch" '[ $rc -ne 0 ] && grep -q REPLAY_UNKNOWN <<<"$out" && ! grep -q FETCH_FAILED <<<"$out"'

echo "Step 4, vendored copy"
out="$(run "$(fill REPO= REPLAY="$REPLAY_FILE" <<<"$VEND_BLOCK")")"; rc=$?
check "empty REPO -> NOT_A_VIBESTACK_INSTALL, non-zero" '[ $rc -ne 0 ] && grep -q NOT_A_VIBESTACK_INSTALL <<<"$out"'
make_pack "$WORK/vend"
out="$(run "$(fill REPO="$WORK/vend" REPLAY= <<<"$VEND_BLOCK")")"; rc=$?
check "empty REPLAY -> REPLAY_UNKNOWN, copy not moved" '[ $rc -ne 0 ] && grep -q REPLAY_UNKNOWN <<<"$out" && [ -f "$WORK/vend/install" ] && [ ! -e "$WORK/vend.bak" ]'

echo "Step 4.5, vendored copy"
mkdir -p "$WORK/proj"; make_pack "$WORK/proj/vs"; : > "$WORK/proj/vs/marker"
out="$(run "$(fill REPO= LOCAL_VIBESTACK="$WORK/proj/vs" <<<"$SYNC_BLOCK")")"; rc=$?
check "sync with empty REPO -> SYNC_SKIPPED, copy untouched" '[ $rc -ne 0 ] && grep -q SYNC_SKIPPED <<<"$out" && [ -f "$WORK/proj/vs/marker" ] && [ ! -e "$WORK/proj/vs.bak" ]'
out="$(run "$(fill _ROOT= LOCAL_VIBESTACK="$WORK/proj/vs" <<<"$TEAM_BLOCK")")"; rc=$?
check "team removal with empty _ROOT -> SKIP, copy kept" 'grep -q "^SKIP" <<<"$out" && [ -f "$WORK/proj/vs/marker" ]'
mkdir -p "$WORK/proj/notpack"; : > "$WORK/proj/notpack/marker"
out="$(run "$(fill _ROOT="$WORK/proj" LOCAL_VIBESTACK="$WORK/proj/notpack" <<<"$TEAM_BLOCK")")"; rc=$?
check "team removal of a non-vibestack dir -> SKIP, dir kept" 'grep -q "^SKIP" <<<"$out" && [ -f "$WORK/proj/notpack/marker" ]'

echo "Step 4.75, migrations"
make_pack "$WORK/mig"; mkdir -p "$WORK/mig/skills/vibe-upgrade/migrations"
printf '#!/usr/bin/env bash\necho "$VIBESTACK_INSTALL_DIR" > "%s/mig-ran"\n' "$WORK" \
  > "$WORK/mig/skills/vibe-upgrade/migrations/v2.0.0.sh"
out="$(run "$(fill REPO="$WORK/mig" OLD_VERSION= <<<"$MIG_BLOCK")")"; rc=$?
check "empty OLD_VERSION -> non-zero, no migration ran" '[ $rc -ne 0 ] && [ ! -f "$WORK/mig-ran" ]'
out="$(run "$(fill REPO="$WORK/mig" <<<"$MIG_BLOCK")")"; rc=$?
check "unfilled <OLD_VERSION> placeholder -> non-zero, no migration ran" '[ $rc -ne 0 ] && [ ! -f "$WORK/mig-ran" ]'
out="$(run "$(fill REPO= OLD_VERSION="1.0.0" <<<"$MIG_BLOCK")")"; rc=$?
check "empty REPO -> MIGRATIONS_SKIPPED, no migration ran" '[ $rc -ne 0 ] && grep -q MIGRATIONS_SKIPPED <<<"$out" && [ ! -f "$WORK/mig-ran" ]'
out="$(run "$(fill REPO="$WORK/mig" OLD_VERSION="1.0.0" <<<"$MIG_BLOCK")")"; rc=$?
check "migration receives VIBESTACK_INSTALL_DIR" '[ "$(cat "$WORK/mig-ran" 2>/dev/null)" = "$WORK/mig" ]'
rm -f "$WORK/mig-ran"
out="$(run "$(fill REPO="$WORK/mig" OLD_VERSION="2.0.0" <<<"$MIG_BLOCK")")"; rc=$?
check "migration for the current version is not re-run" '[ ! -f "$WORK/mig-ran" ]'

echo ""
echo "vibe-upgrade guards: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
