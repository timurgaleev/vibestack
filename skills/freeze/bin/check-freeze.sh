#!/usr/bin/env bash
# check-freeze.sh — PreToolUse hook for /freeze skill
# Reads JSON from stdin, checks if file_path is within the freeze boundary.
# Returns {"permissionDecision":"deny","message":"..."} to block, or {} to allow.
set -euo pipefail

INPUT=$(cat)

STATE_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}"
FREEZE_FILE="$STATE_DIR/freeze-dir.txt"

[ ! -f "$FREEZE_FILE" ] && echo '{}' && exit 0

FREEZE_DIR=$(tr -d '[:space:]' < "$FREEZE_FILE")

[ -z "$FREEZE_DIR" ] && echo '{}' && exit 0

# Extract file_path from tool_input JSON
FILE_PATH=$(printf '%s' "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//' || true)

if [ -z "$FILE_PATH" ]; then
  FILE_PATH=$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)
fi

[ -z "$FILE_PATH" ] && echo '{}' && exit 0

# Resolve to absolute path
case "$FILE_PATH" in
  /*) ;;
  *) FILE_PATH="$(pwd)/$FILE_PATH" ;;
esac

# Normalize: remove double slashes and trailing slash
FILE_PATH=$(printf '%s' "$FILE_PATH" | sed 's|/\+|/|g;s|/$||')

# Resolve symlinks for the full path (POSIX-portable, works on macOS).
# When the path is itself a directory (e.g. the freeze boundary, or /tmp which
# symlinks to /private/tmp), cd into it directly so the leaf component is
# resolved too. Otherwise fall back to resolving the parent and appending the
# basename. Guards against the "//foo" double-slash that occurs when the
# resolved parent is the root directory.
_resolve_path() {
  local _path="$1"
  local _resolved=""
  if [ -d "$_path" ]; then
    _resolved="$(cd "$_path" 2>/dev/null && pwd -P)" || _resolved=""
  fi
  if [ -z "$_resolved" ]; then
    local _dir _base
    _dir="$(dirname "$_path")"
    _base="$(basename "$_path")"
    if [ -d "$_dir" ]; then
      _dir="$(cd "$_dir" 2>/dev/null && pwd -P)" || _dir="$(dirname "$_path")"
    fi
    if [ "$_dir" = "/" ]; then
      _resolved="/$_base"
    else
      _resolved="$_dir/$_base"
    fi
  fi
  printf '%s' "$_resolved"
}
FILE_PATH=$(_resolve_path "$FILE_PATH")
FREEZE_DIR=$(_resolve_path "$FREEZE_DIR")

case "$FILE_PATH" in
  "${FREEZE_DIR}/"*|"${FREEZE_DIR}")
    echo '{}'
    ;;
  *)
    printf '{"permissionDecision":"deny","message":"[freeze] Blocked: %s is outside the freeze boundary (%s). Only edits within the frozen directory are allowed."}\n' "$FILE_PATH" "$FREEZE_DIR"
    ;;
esac
