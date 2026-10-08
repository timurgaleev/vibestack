#!/usr/bin/env bash
# test-update-check.sh — bin/vibe-update-check against a local fake remote.
#
# Covers: the installed copy in ~/.vibestack/bin finds the git checkout through
# the skills' bin symlinks; a check that cannot read the remote says
# CHECK_FAILED under --force (never the silence that means "up to date") and
# stays quiet in a skill preamble; the day stamp is written only after the
# remote VERSION was read, so one offline session cannot hide a release.
#
# Usage: test/test-update-check.sh [path/to/vibe-update-check]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/bin/vibe-update-check}"
[ -f "$BIN" ] || { echo "no such file: $BIN" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME GIT_SSH_COMMAND

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

G="git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c commit.gpgsign=false"
$G init -q --bare "$TMP/remote.git"
git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/main
$G init -q "$TMP/seed"
echo 1.0.0 > "$TMP/seed/VERSION"; : > "$TMP/seed/install"
mkdir -p "$TMP/seed/skills/careful/bin"; : > "$TMP/seed/skills/careful/bin/x"
$G -C "$TMP/seed" add -A; $G -C "$TMP/seed" commit -qm init
git -C "$TMP/seed" push -q "$TMP/remote.git" main
git clone -q "$TMP/remote.git" "$TMP/co"

# Installed layout: a copy of the script in ~/.vibestack/bin, the skills' bin
# directories symlinked back into the checkout.
H="$TMP/home"
mkdir -p "$H/.vibestack/bin" "$H/.claude/skills/careful"
cp "$BIN" "$H/.vibestack/bin/vibe-update-check"; chmod +x "$H/.vibestack/bin/vibe-update-check"; echo 1.0.0 > "$H/.vibestack/version"
ln -s "$TMP/co/skills/careful/bin" "$H/.claude/skills/careful/bin"
run() { HOME="$H" "$H/.vibestack/bin/vibe-update-check" "$@"; }

echo "installed layout"
out="$(run --force)"
[ -z "$out" ] && ok "current version: silent" || no "current version printed '$out'"
echo 1.1.0 > "$TMP/seed/VERSION"; $G -C "$TMP/seed" commit -qam bump
git -C "$TMP/seed" push -q "$TMP/remote.git" main
out="$(run --force)"
case "$out" in
  "UPDATE: vibestack 1.1.0 is available (you have 1.0.0)"*) ok "finds the checkout through a skill bin link" ;;
  *) no "behind remote: got '$out'" ;;
esac
[ -f "$H/.vibestack/.update-check-stamp" ] && ok "day stamp written after a successful read" \
                                          || no "no day stamp after a successful read"

echo "throttle"
echo 1.2.0 > "$TMP/seed/VERSION"; $G -C "$TMP/seed" commit -qam bump2
git -C "$TMP/seed" push -q "$TMP/remote.git" main
out="$(run)"
[ -z "$out" ] && ok "a fresh day stamp throttles the preamble check" || no "throttled run printed '$out'"
# GNU stat (Linux) reads `-f` as --file-system; the age must still come out right.
if command -v gstat >/dev/null 2>&1; then
  mkdir -p "$TMP/gnu"; ln -s "$(command -v gstat)" "$TMP/gnu/stat"
  out="$(PATH="$TMP/gnu:$PATH" run)"
  [ -z "$out" ] && ok "throttle holds with GNU stat" || no "GNU stat: throttled run printed '$out'"
fi
echo 1.1.0 > "$TMP/seed/VERSION"; $G -C "$TMP/seed" commit -qam back
git -C "$TMP/seed" push -q "$TMP/remote.git" main

echo "failed fetch"
rm -f "$H/.vibestack/.update-check-stamp"
git -C "$TMP/co" remote set-url origin "$TMP/missing.git"
out="$(run --force)"; rc=$?
case "$out" in
  "CHECK_FAILED git fetch"*) ok "--force reports CHECK_FAILED" ;;
  *) no "--force on a failed fetch: got '$out'" ;;
esac
[ "$rc" -eq 0 ] && ok "a failed check still exits 0" || no "a failed check exited $rc"
[ ! -f "$H/.vibestack/.update-check-stamp" ] && ok "no day stamp without a read" \
                                             || no "day stamp written although the remote was never read"
[ -f "$H/.vibestack/.update-check-failed" ] && ok "failure stamp written (hourly retry)" \
                                            || no "no failure stamp after a failed check"
out="$(run)"
[ -z "$out" ] && ok "preamble mode stays quiet on failure" || no "preamble mode printed '$out'"

echo "no checkout"
H2="$TMP/h2"
mkdir -p "$H2/.vibestack/bin"
cp "$BIN" "$H2/.vibestack/bin/vibe-update-check"; chmod +x "$H2/.vibestack/bin/vibe-update-check"; echo 1.0.0 > "$H2/.vibestack/version"
out="$(HOME="$H2" "$H2/.vibestack/bin/vibe-update-check" --force)"
case "$out" in
  CHECK_FAILED*) ok "no checkout found -> CHECK_FAILED, not silence" ;;
  *) no "no checkout: got '$out'" ;;
esac

echo
echo "update-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
