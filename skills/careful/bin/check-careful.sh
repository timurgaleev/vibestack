#!/usr/bin/env bash
# check-careful.sh — PreToolUse hook for /careful skill
# Reads JSON from stdin, checks Bash command for destructive patterns.
# Returns {"permissionDecision":"ask","message":"..."} to warn, or {} to allow.
set -euo pipefail

# Opt-in debug logging. No-op unless VIBESTACK_DEBUG=1.
# All side effects run in a subshell so errors never propagate back into the
# hook's decision flow (preserves set -euo pipefail safety).
# WARNING: when enabled, this records the full bash command being evaluated.
# Commands may contain secrets. Only enable on machines where ~/.vibestack/hook.log
# is acceptable as an audit trail.
_vibestack_log() {
  [ "${VIBESTACK_DEBUG:-0}" = "1" ] || return 0
  (
    set +e
    local hook="$1" decision="$2" reason="$3" payload="${4:-}"
    local log_dir="${VIBESTACK_HOME:-$HOME/.vibestack}"
    local log_file="$log_dir/hook.log"
    local lock_file="$log_dir/hook.log.lock"
    mkdir -p "$log_dir" 2>/dev/null
    # Rotate at >1MB via atomic rename (never truncate-in-place)
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

INPUT=$(cat)

# Extract "command" field — grep/sed first, python fallback for escaped quotes
CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//' || true)

if [ -z "$CMD" ]; then
  CMD=$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_input",{}).get("command",""))' 2>/dev/null || true)
fi

if [ -z "$CMD" ]; then
  _vibestack_log careful allow no-command ""
  echo '{}'
  exit 0
fi

CMD_LOWER=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')

# Safe exceptions: rm -rf of build artifacts is always allowed
if printf '%s' "$CMD" | grep -qE 'rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+|--recursive[[:space:]]+)' 2>/dev/null; then
  SAFE_ONLY=true
  # Strip 'rm' and all leading flags; remaining tokens are the target paths
  RM_ARGS=$(printf '%s' "$CMD" | sed -E 's/^[[:space:]]*rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(--[a-z-]+[[:space:]]+)*(--[[:space:]]+)?//')
  for target in $RM_ARGS; do
    case "$target" in
      */node_modules|node_modules|*/\.next|\.next|*/dist|dist|*/__pycache__|__pycache__|*/\.cache|\.cache|*/build|build|*/\.turbo|\.turbo|*/coverage|coverage)
        ;;
      -*)
        ;;
      *)
        SAFE_ONLY=false
        break
        ;;
    esac
  done
  if [ "$SAFE_ONLY" = true ]; then
    _vibestack_log careful allow safe-build-artifact "$CMD"
    echo '{}'
    exit 0
  fi
fi

WARN=""

if printf '%s' "$CMD" | grep -qE 'rm[[:space:]]+(-[a-zA-Z]*r|--recursive)' 2>/dev/null; then
  WARN="Destructive: recursive delete (rm -r). This permanently removes files."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD_LOWER" | grep -qE 'drop\s+(table|database)' 2>/dev/null; then
  WARN="Destructive: SQL DROP detected. This permanently deletes database objects."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\b' 2>/dev/null; then
  WARN="Destructive: SQL TRUNCATE detected. This deletes all rows from a table."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force)' 2>/dev/null; then
  WARN="Destructive: git force-push rewrites remote history. Other contributors may lose work."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'git\s+reset\s+--hard' 2>/dev/null; then
  WARN="Destructive: git reset --hard discards all uncommitted changes."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'git\s+(checkout|restore)\s+\.' 2>/dev/null; then
  WARN="Destructive: discards all uncommitted changes in the working tree."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'kubectl\s+delete' 2>/dev/null; then
  WARN="Destructive: kubectl delete removes Kubernetes resources. May impact production."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'docker\s+(rm\s+-f|system\s+prune)' 2>/dev/null; then
  WARN="Destructive: Docker force-remove or prune. May delete running containers or cached images."
fi

if [ -n "$WARN" ]; then
  _vibestack_log careful ask "$WARN" "$CMD"
  WARN_ESCAPED=$(printf '%s' "$WARN" | sed 's/"/\\"/g')
  printf '{"permissionDecision":"ask","message":"[careful] %s"}\n' "$WARN_ESCAPED"
else
  _vibestack_log careful allow no-pattern-match "$CMD"
  echo '{}'
fi
