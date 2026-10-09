#!/usr/bin/env bash
# check-freeze.sh — PreToolUse hook for /freeze skill
# Reads JSON from stdin, checks if the edited path is within the freeze
# boundary: file_path for Edit/Write, notebook_path for NotebookEdit.
# Returns a PreToolUse hookSpecificOutput with permissionDecision "deny" to block,
# or {} to allow. The decision MUST be nested under hookSpecificOutput — Claude
# Code ignores a top-level permissionDecision, which silently no-ops the block.
#
# Polarity: freeze is a DENY-tier hook, so an unreadable payload DENIES
# (fail closed), and so does a payload that parses but carries no path: the
# hook is registered only on Edit, Write and NotebookEdit, so a pathless
# payload is a schema it does not understand. Any unexpected death denies too
# (the EXIT trap below). This is the opposite edge-handling from careful's
# ask-tier and intentionally so: /guard runs both, and a boundary that fails
# open is not a boundary.
set -euo pipefail

# Deny-tier backstop: any unexpected non-zero exit (a failing pipeline under
# set -e, an unreadable state file, a deleted cwd) would otherwise end with no
# decision JSON, which Claude Code treats as non-blocking — the edit proceeds.
# Every deliberate output sets _FREEZE_DECIDED right after it is printed, so a
# late failure never prints a second JSON object.
_FREEZE_DECIDED=""
_freeze_backstop() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$_FREEZE_DECIDED" ]; then
    _FREEZE_DECIDED=1
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[freeze] Hook failed unexpectedly (exit %s) - blocked, fail closed. Check ~/.vibestack/freeze-dir.txt or run /unfreeze."}}\n' "$rc"
    exit 0
  fi
}
trap _freeze_backstop EXIT

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
  _FREEZE_DECIDED=1
  exit 0
fi

STATE_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}"
FREEZE_FILE="$STATE_DIR/freeze-dir.txt"

if [ ! -f "$FREEZE_FILE" ]; then
  _vibestack_log freeze allow no-freeze-state ""
  echo '{}'
  _FREEZE_DECIDED=1
  exit 0
fi

# Line 1 is the boundary. freeze-state.sh writes it verbatim and stamps line 2
# with its owner token, so that line is used as-is; a hand-written file gets
# LEADING/TRAILING whitespace trimmed. A blanket `tr -d '[:space:]'` would
# delete INTERNAL spaces too, so "~/My Project/src" could never match anything.
# An unreadable file fails here and the backstop denies.
FREEZE_DIR=$(sed -n '1p' "$FREEZE_FILE")
case "$(sed -n '2p' "$FREEZE_FILE")" in
  vibe-freeze-v1:*) ;;
  *) FREEZE_DIR=$(printf '%s\n' "$FREEZE_DIR" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') ;;
esac
# A literal leading ~ in the state file never matches absolute tool paths
# (tilde is not expanded from variables) — expand it here.
case "$FREEZE_DIR" in
  "~/"*) FREEZE_DIR="$HOME/${FREEZE_DIR#\~/}" ;;
  "~") FREEZE_DIR="$HOME" ;;
esac

if [ -z "$FREEZE_DIR" ]; then
  _vibestack_log freeze allow empty-freeze-dir ""
  echo '{}'
  _FREEZE_DECIDED=1
  exit 0
fi

# A relative boundary means nothing without the cwd it was written from, and
# the hook's cwd is not that. Deny instead of guessing; the state is kept.
case "$FREEZE_DIR" in
  /*) ;;
  *)
    _vibestack_log freeze deny relative-boundary ""
    vibe_hook_decision deny "[freeze] The saved boundary '$FREEZE_DIR' is a relative path, which is ambiguous. Blocked (fail closed). Re-run /freeze with the directory, or run /unfreeze."
    _FREEZE_DECIDED=1
    exit 0
    ;;
esac

# Extract the edited path with the shared real-JSON parser. Edit and Write
# carry tool_input.file_path; NotebookEdit carries tool_input.notebook_path,
# and reading file_path alone let every notebook edit through.
set +e
PATH_FIELD=file_path
FILE_PATH=$(vibe_hook_extract_field "$INPUT" file_path)
EXTRACT_RC=$?
if [ "$EXTRACT_RC" -eq 0 ] && [ -z "$FILE_PATH" ]; then
  PATH_FIELD=notebook_path
  FILE_PATH=$(vibe_hook_extract_field "$INPUT" notebook_path)
  EXTRACT_RC=$?
fi
set -e

# Unparseable payload (or no parser available): DENY. A boundary hook that
# allows what it cannot read is not a boundary — and empty stdin is unreadable
# too, since a real PreToolUse call always carries a payload.
if [ "$EXTRACT_RC" -ne 0 ]; then
  _vibestack_log freeze deny unparseable-payload ""
  _vibestack_analytics deny unparseable_payload
  vibe_hook_decision deny "[freeze] Could not parse the tool payload to check the freeze boundary. Blocked (fail closed). Freeze boundary: $FREEZE_DIR"
  _FREEZE_DECIDED=1
  exit 0
fi

# Parsed fine but neither path field is present: the hook cannot tell what
# the edit touches, so it cannot vouch for the boundary — deny.
if [ -z "$FILE_PATH" ]; then
  _vibestack_log freeze deny no-file-path ""
  _vibestack_analytics deny no_file_path
  vibe_hook_decision deny "[freeze] The tool payload names no file_path or notebook_path, so the freeze boundary cannot be checked. Blocked (fail closed). Freeze boundary: $FREEZE_DIR"
  _FREEZE_DECIDED=1
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
  # Write creates missing parent directories, so the parent may not exist yet.
  # Resolve the nearest existing ancestor and append the missing components
  # verbatim. A "." or ".." among them, or a dangling symlink, cannot be
  # resolved without guessing what the write will create, so the whole path is
  # unresolvable (empty output) and the caller denies.
  local _tail="$_base" _c
  case "$_base" in .|..) return 1 ;; esac
  while [ ! -d "$_dir" ]; do
    [ -L "$_dir" ] && return 1
    _c="$(basename "$_dir")"
    case "$_c" in .|..) return 1 ;; esac
    _tail="$_c/$_tail"
    _dir="$(dirname "$_dir")"
  done
  _dir="$(cd "$_dir" 2>/dev/null && pwd -P)" || return 1
  if [ "$_dir" = "/" ]; then
    printf '/%s' "$_tail"
  else
    printf '%s/%s' "$_dir" "$_tail"
  fi
}
FILE_PATH=$(_resolve_path "$FILE_PATH") || FILE_PATH=""
FREEZE_DIR=$(_resolve_path "$FREEZE_DIR") || FREEZE_DIR=""
if [ -z "$FILE_PATH" ] || [ -z "$FREEZE_DIR" ]; then
  _vibestack_log freeze deny unresolvable-path "$FILE_PATH"
  _vibestack_analytics deny unresolvable_path
  vibe_hook_decision deny "[freeze] Blocked: the $PATH_FIELD (or the freeze boundary) runs through a directory that does not exist yet via '.', '..' or a dangling symlink, so it cannot be checked against the boundary. Use a plain path. Freeze boundary: $(sed -n '1p' "$FREEZE_FILE")"
  _FREEZE_DECIDED=1
  exit 0
fi

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
    _FREEZE_DECIDED=1
    ;;
  *)
    _vibestack_log freeze deny outside-boundary "$FILE_PATH (boundary=$FREEZE_DIR)"
    _vibestack_analytics deny boundary_deny
    # The reason is JSON-encoded by the shared helper. Never interpolate paths
    # into hand-built JSON: a path containing a quote or newline produces
    # malformed JSON, and the deny silently no-ops.
    vibe_hook_decision deny "[freeze] Blocked: $PATH_FIELD $FILE_PATH is outside the freeze boundary ($FREEZE_DIR). Only edits within the frozen directory are allowed; run /unfreeze to remove the boundary."
    _FREEZE_DECIDED=1
    ;;
esac
