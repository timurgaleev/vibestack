#!/usr/bin/env bash
# freeze-state.sh — the one writer of the freeze boundary state file.
#
#   freeze-state.sh set DIRECTORY      user-chosen boundary (/freeze, /guard);
#                                      replaces any existing boundary
#   freeze-state.sh acquire DIRECTORY  run-owned boundary (/investigate); keeps
#                                      any existing boundary untouched
#   freeze-state.sh release OWNER      removes the boundary only if OWNER wrote it
#   freeze-state.sh clear              user-requested removal (/unfreeze)
#
# State file ($VIBESTACK_HOME/freeze-dir.txt):
#   line 1  the boundary: an absolute, physical directory path
#   line 2  vibe-freeze-v1:<32 hex owner token>
# check-freeze.sh reads line 1 only.
#
# The boundary is deny-tier, so every failure here is loud: a directory that
# does not resolve, or that resolves to /, is refused with a non-zero exit and
# the existing state is left exactly as it was. Writes go through mktemp + mv
# so the hook never reads a half-written file, and every mutation runs under a
# mkdir mutex so a /freeze cannot interleave with an /investigate release.
set -euo pipefail

# cd prints the directory when CDPATH matches, which would corrupt $(cd ...).
CDPATH=

STATE_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}"
STATE_FILE="$STATE_DIR/freeze-dir.txt"
MUTEX="$STATE_DIR/.freeze-mutation.lock"
OWNER_PREFIX="vibe-freeze-v1:"

usage() {
  echo 'Usage: freeze-state.sh set|acquire DIRECTORY | release OWNER | clear' >&2
  exit 2
}

ACTION="${1:-}"
case "$ACTION" in
  set|acquire)
    [ -n "${2:-}" ] || { echo 'FREEZE_ERROR: a directory is required. No boundary changed.' >&2; exit 2; } ;;
  release)
    [ -n "${2:-}" ] || { echo 'FREEZE_ERROR: an owner token is required. No boundary changed.' >&2; exit 2; } ;;
  clear) ;;
  *) usage ;;
esac

mkdir -p "$STATE_DIR"

if ! mkdir "$MUTEX" 2>/dev/null; then
  echo "FREEZE_BUSY: another freeze-state writer holds $MUTEX. Retry once it finishes; if no writer is running, the lock was abandoned by a killed session — remove that directory with the user's agreement. No boundary changed." >&2
  exit 1
fi
TEMP=""
_finish() {
  local rc=$?
  [ -z "$TEMP" ] || rm -f -- "$TEMP"
  rmdir "$MUTEX" 2>/dev/null || true
  exit "$rc"
}
trap _finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A symlink or a directory where the state file belongs is not ours to replace.
if [ -L "$STATE_FILE" ] || { [ -e "$STATE_FILE" ] && [ ! -f "$STATE_FILE" ]; }; then
  echo "FREEZE_ERROR: $STATE_FILE is not a regular file. Inspect it with the user; no boundary changed." >&2
  exit 1
fi

# _resolve_dir DIR — sets RESOLVED to the physical absolute path of DIR, or
# fails. The trailing x keeps a directory name that ends in a newline intact
# through command substitution, which would otherwise strip it and name
# another path; the result goes into a variable for the same reason.
RESOLVED=""
_resolve_dir() {
  local out
  out=$(cd -- "$1" 2>/dev/null && pwd -P && printf x) || return 1
  RESOLVED="${out%$'\nx'}"
}

_write_boundary() {
  local dir="$1" boundary owner
  if ! _resolve_dir "$dir"; then
    echo "FREEZE_ERROR: '$dir' is not a directory that can be entered. No boundary changed." >&2
    exit 1
  fi
  boundary="$RESOLVED"
  case "$boundary" in
    *$'\n'*|*$'\r'*)
      echo 'FREEZE_ERROR: the boundary path must fit on one line. No boundary changed.' >&2
      exit 1 ;;
    /)
      echo 'FREEZE_ERROR: refusing / as a boundary — it contains every path, so it would block nothing. No boundary changed.' >&2
      exit 1 ;;
    /*) ;;
    *)
      echo "FREEZE_ERROR: '$boundary' did not resolve to an absolute path. No boundary changed." >&2
      exit 1 ;;
  esac
  owner=$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')
  if [ "${#owner}" -ne 32 ]; then
    echo 'FREEZE_ERROR: could not generate an owner token. No boundary changed.' >&2
    exit 1
  fi
  TEMP=$(mktemp "$STATE_DIR/.freeze-write.XXXXXX")
  printf '%s\n%s%s\n' "$boundary" "$OWNER_PREFIX" "$owner" > "$TEMP"
  mv -f -- "$TEMP" "$STATE_FILE"
  TEMP=""
  printf 'FREEZE_OWNER=%s\nFREEZE_DIR=%s\n' "$owner" "$boundary"
}

case "$ACTION" in
  set)
    _write_boundary "$2"
    ;;
  acquire)
    if [ -e "$STATE_FILE" ]; then
      echo "FREEZE_PRESERVED: a boundary is already set ($(head -n 1 "$STATE_FILE")). It belongs to the user or another run — keep it and do not release it."
      exit 0
    fi
    _write_boundary "$2"
    ;;
  release)
    OWNER="$2"
    case "$OWNER" in
      *[!a-f0-9]*)
        echo 'FREEZE_ERROR: invalid owner token. No boundary changed.' >&2
        exit 2 ;;
    esac
    if [ "${#OWNER}" -ne 32 ]; then
      echo 'FREEZE_ERROR: invalid owner token. No boundary changed.' >&2
      exit 2
    fi
    if [ -f "$STATE_FILE" ] && [ "$(sed -n '2p' "$STATE_FILE")" = "$OWNER_PREFIX$OWNER" ]; then
      rm -f -- "$STATE_FILE"
      echo 'FREEZE_RELEASED: the boundary this run acquired was removed.'
    else
      echo 'FREEZE_PRESERVED: the current boundary is not owned by this token; it was left untouched.'
    fi
    ;;
  clear)
    if [ -f "$STATE_FILE" ]; then
      PREV=$(head -n 1 "$STATE_FILE")
      rm -f -- "$STATE_FILE"
      echo "FREEZE_CLEARED: boundary removed (was: $PREV). Edits are allowed everywhere."
    else
      echo 'FREEZE_CLEARED: no boundary was set.'
    fi
    ;;
esac
