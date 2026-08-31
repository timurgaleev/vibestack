#!/usr/bin/env bash
# check-freeze.sh — PreToolUse hook for /freeze skill
# Reads JSON from stdin, checks if file_path is within the freeze boundary.
# Returns a PreToolUse hookSpecificOutput with permissionDecision "deny" to block,
# or {} to allow. The decision MUST be nested under hookSpecificOutput — Claude
# Code ignores a top-level permissionDecision, which silently no-ops the block.
#
# Polarity: freeze is a DENY-tier hook, so an unreadable payload DENIES
# (fail closed). A payload that parses but has no file_path is a non-file
# tool — allow. This is the opposite edge-handling from careful's ask-tier
# and intentionally so: /guard runs both, and a boundary that fails open is
# not a boundary.
set -euo pipefail

# Opt-in debug logging. No-op unless VIBESTACK_DEBUG=1.
# Subshell-isolated so logging errors never affect the hook decision.
# WARNING: when enabled, records the file paths Claude attempts to edit.
_vibestack_log() {
  [ "${VIBESTACK_DEBUG:-0}" = "1" ] || return 0
  (
    set +e
    local hook="$1" decision="$2" reason="$3" payload="${4:-}"
    local log_dir="${VIBESTACK_HOME:-$HOME/.vibestack}"
    local log_file="$log_dir/hook.log"
    local lock_file="$log_dir/hook.log.lock"
    mkdir -p "$log_dir" 2>/dev/null
    if [ -f "$log_file" ]; then
      local size
      size=$(wc -c < "$log_file" 2>/dev/null || echo 0)
      if [ "$size" -gt 1048576 ] 2>/dev/null; then
        mv "$log_file" "$log_file.1" 2>/dev/null
      fi
    fi
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local line
    line=$(printf '%s hook=%s decision=%s reason=%s payload=%q\n' \
      "$ts" "$hook" "$decision" "$reason" "$payload")
    if command -v flock >/dev/null 2>&1; then
      (
        flock 9
        printf '%s\n' "$line" >> "$log_file"
      ) 9>"$lock_file"
    else
      printf '%s\n' "$line" >> "$log_file"
    fi
  ) 2>/dev/null
  return 0
}

# Opt-in structured analytics event (same VIBESTACK_DEBUG gate — no unconditional
# egress). Records only skill/decision/pattern/ts/repo, never the file path.
_vibestack_analytics() {
  [ "${VIBESTACK_DEBUG:-0}" = "1" ] || return 0
  (
    set +e
    local decision="$1" pattern="$2"
    local dir="${VIBESTACK_HOME:-$HOME/.vibestack}/analytics"
    mkdir -p "$dir" 2>/dev/null
    local ts repo
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo unknown)
    printf '{"event":"hook_fire","skill":"freeze","decision":"%s","pattern":"%s","ts":"%s","repo":"%s"}\n' \
      "$decision" "$pattern" "$ts" "$repo" >> "$dir/skill-usage.jsonl" 2>/dev/null
  ) 2>/dev/null
  return 0
}

INPUT=$(cat)

# Shared JSON helpers (extractor + encoder) — one copy for careful AND freeze.
# freeze previously carried its own grep-first extractor which truncated at
# escaped quotes and failed OPEN; the shared file kills that drift class.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Freeze is deny-tier: if its own helpers are missing/broken (partial install,
# mid-upgrade state), the boundary must fail CLOSED — inline JSON, since the
# encoder we would normally use lives in the file that just failed to load.
# NOTE: bash treats `.` on a MISSING file as fatal in non-interactive shells
# (an if-guard cannot catch it) — the existence check must come first.
_HOOK_HELPER="$_HOOK_DIR/../../careful/bin/hook-extract.sh"
if [ ! -f "$_HOOK_HELPER" ] || ! . "$_HOOK_HELPER" 2>/dev/null; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[freeze] Hook helpers unavailable (broken install?) - blocked, fail closed. Reinstall vibestack or run /unfreeze."}}\n'
  exit 0
fi

STATE_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}"
FREEZE_FILE="$STATE_DIR/freeze-dir.txt"

if [ ! -f "$FREEZE_FILE" ]; then
  _vibestack_log freeze allow no-freeze-state ""
  echo '{}'
  exit 0
fi

# First line, trimmed of LEADING/TRAILING whitespace only. A blanket
# `tr -d '[:space:]'` deletes INTERNAL spaces too, so a boundary like
# "~/My Project/src" could never match anything — every edit denied (or the
# mangled path accidentally allowed the wrong tree).
FREEZE_DIR=$(head -n 1 "$FREEZE_FILE" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
# A literal leading ~ in the state file never matches absolute tool paths
# (tilde is not expanded from variables) — expand it here.
case "$FREEZE_DIR" in
  "~/"*) FREEZE_DIR="$HOME/${FREEZE_DIR#\~/}" ;;
  "~") FREEZE_DIR="$HOME" ;;
esac

if [ -z "$FREEZE_DIR" ]; then
  _vibestack_log freeze allow empty-freeze-dir ""
  echo '{}'
  exit 0
fi

# Extract file_path from tool_input with the shared real-JSON parser.
set +e
FILE_PATH=$(vibe_hook_extract_field "$INPUT" file_path)
EXTRACT_RC=$?
set -e

# Unparseable payload (or no parser available): DENY. A boundary hook that
# allows what it cannot read is not a boundary.
if [ "$EXTRACT_RC" -ne 0 ] && [ -n "$INPUT" ]; then
  _vibestack_log freeze deny unparseable-payload ""
  _vibestack_analytics deny unparseable_payload
  vibe_hook_decision deny "[freeze] Could not parse the tool payload to check the freeze boundary. Blocked (fail closed). Freeze boundary: $FREEZE_DIR"
  exit 0
fi

# Parsed fine but no file_path field: a non-file tool payload — allow.
if [ -z "$FILE_PATH" ]; then
  _vibestack_log freeze allow no-file-path ""
  echo '{}'
  exit 0
fi

# Resolve to absolute path
case "$FILE_PATH" in
  /*) ;;
  *) FILE_PATH="$(pwd)/$FILE_PATH" ;;
esac

# Normalize: remove double slashes and trailing slash
FILE_PATH=$(printf '%s' "$FILE_PATH" | sed 's|/\+|/|g;s|/$||')

# Resolve symlinks and .. sequences (POSIX-portable, works on macOS).
# The FULL path is resolved, including the FINAL component: resolving only the
# parent directory let an in-boundary symlink pointing at an out-of-boundary
# target sail through the check while the actual write landed outside the
# boundary. A final component that is a symlink is followed (bounded,
# cycle-safe) so the TARGET gets checked; a final component that does not exist
# yet (new file) has nothing to follow and parent resolution is correct.
_resolve_path() {
  local _p="$1" _dir _base _tgt _i=0
  # The root directory is its own dirname and its own basename, so the generic
  # path below reassembles it as "//" — a boundary string nothing matches,
  # which turns a freeze on / into "deny every edit".
  [ "$_p" = "/" ] && { printf '/'; return; }
  while [ -L "$_p" ] && [ "$_i" -lt 40 ]; do
    _tgt=$(readlink "$_p" 2>/dev/null) || break
    case "$_tgt" in
      /*) _p="$_tgt" ;;
      *) _p="$(dirname "$_p")/$_tgt" ;;
    esac
    _i=$((_i + 1))
  done
  _dir="$(dirname "$_p")"
  _base="$(basename "$_p")"
  _dir="$(cd "$_dir" 2>/dev/null && pwd -P || printf '%s' "$_dir")"
  if [ "$_dir" = "/" ]; then
    printf '/%s' "$_base"
  else
    printf '%s/%s' "$_dir" "$_base"
  fi
}
FILE_PATH=$(_resolve_path "$FILE_PATH")
FREEZE_DIR=$(_resolve_path "$FREEZE_DIR")

# A boundary of / contains every absolute path; matching "${FREEZE_DIR}/"*
# there would build the pattern "//"* and deny everything.
_INSIDE=0
if [ "$FREEZE_DIR" = "/" ]; then
  _INSIDE=1
else
  case "$FILE_PATH" in
    "${FREEZE_DIR}/"*|"${FREEZE_DIR}") _INSIDE=1 ;;
  esac
fi

case "$_INSIDE" in
  1)
    _vibestack_log freeze allow inside-boundary "$FILE_PATH"
    echo '{}'
    ;;
  *)
    _vibestack_log freeze deny outside-boundary "$FILE_PATH (boundary=$FREEZE_DIR)"
    _vibestack_analytics deny boundary_deny
    # The reason is JSON-encoded by the shared helper. Never interpolate paths
    # into hand-built JSON: a path containing a quote or newline produces
    # malformed JSON, and the deny silently no-ops.
    vibe_hook_decision deny "[freeze] Blocked: $FILE_PATH is outside the freeze boundary ($FREEZE_DIR). Only edits within the frozen directory are allowed."
    ;;
esac
