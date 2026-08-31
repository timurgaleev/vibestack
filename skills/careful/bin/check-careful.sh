#!/usr/bin/env bash
# check-careful.sh — PreToolUse hook for /careful skill
# Reads JSON from stdin, checks Bash command for destructive patterns.
# Two tiers:
#   HIGH   — a tiny set of catastrophic SIMPLE commands returns "deny"
#            (best-effort advisory hard-stop, not a policy boundary).
#   MEDIUM — the destructive families below return "ask" (always overridable).
# The decision MUST be nested under hookSpecificOutput — Claude Code ignores a
# top-level permissionDecision, which silently no-ops the warning.
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

# Opt-in structured analytics event (same VIBESTACK_DEBUG gate as hook.log — no
# unconditional egress, honoring the no-telemetry-by-default policy). Records
# only skill/decision/pattern/ts/repo, never the command text.
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
    printf '{"event":"hook_fire","skill":"careful","decision":"%s","pattern":"%s","ts":"%s","repo":"%s"}\n' \
      "$decision" "$pattern" "$ts" "$repo" >> "$dir/skill-usage.jsonl" 2>/dev/null
  ) 2>/dev/null
  return 0
}

INPUT=$(cat)

# Shared JSON helpers (extractor + encoder) — one copy for careful AND freeze.
# See hook-extract.sh for the drift history that motivated the shared file.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# bash treats `.` on a MISSING file as fatal non-interactively; a partial
# install must degrade to an ASK (this is the ask-tier hook), never silence.
_HOOK_HELPER="$_HOOK_DIR/hook-extract.sh"
if [ ! -f "$_HOOK_HELPER" ] || ! . "$_HOOK_HELPER" 2>/dev/null; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"[careful] Hook helpers unavailable (broken install?) - cannot safety-check this command. Approve only if you know what it does."}}\n'
  exit 0
fi

# Extract the "command" field value from tool_input with a real JSON parser.
#
# The previous extractor was
#   grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"'
# whose [^"]* stops at the first escaped quote in the JSON string value. Any
# destructive command preceded by a quoted argument was therefore truncated
# away before the pattern checks ever ran:
#
#   git commit -m "wip" && rm -rf /   ->  CMD='git commit -m \'   -> allowed
#   bash -c "rm -rf /"                ->  CMD='bash -c \'         -> allowed
#   echo "x"; rm -rf ~                ->  CMD='echo \'            -> allowed
#
# The python fallback only ran when the grep result was EMPTY, so a truncated
# extraction was never repaired. Parse the payload properly instead, and fail
# CLOSED when it cannot be parsed at all — a hook that gates destructive
# commands must not allow-by-default on unreadable input.
set +e
CMD=$(vibe_hook_extract_field "$INPUT" command)
EXTRACT_RC=$?
set -e

# No parser available, or the payload is not parseable JSON. Fail closed.
# Empty stdin counts as unreadable too: a PreToolUse call always carries a
# payload, so nothing on stdin means something upstream broke — not that there
# is nothing to check.
if [ "$EXTRACT_RC" -ne 0 ]; then
  _vibestack_log careful ask unparseable-payload ""
  vibe_hook_decision ask "[careful] Could not parse the tool payload to safety-check this command. Approve only if you know what it does."
  exit 0
fi

# Parsed fine, but there is genuinely no command field (non-Bash payload) — allow.
if [ -z "$CMD" ]; then
  _vibestack_log careful allow no-command ""
  echo '{}'
  exit 0
fi

CMD_LOWER=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')

# --- Shell-obfuscation tripwire ---
# Every check below inspects the command as a STRING, but bash executes what the
# string MEANS after expansion. ${IFS} holds the default field separator and
# contains no literal whitespace, so
#
#   rm${IFS}-rf${IFS}/
#
# matches none of the `rm\s+` patterns while executing as a full recursive
# delete. The same holds for a command assembled by a base64 decode piped to a
# shell. Rather than try to out-parse bash, treat these splitting/decoding
# primitives as a reason to ask: they are vanishingly rare in commands a human
# actually means to run unattended.
if printf '%s' "$CMD" | grep -qE '\$\{IFS\}|\$IFS|\$\(echo[^)]*base64[^)]*\)|base64[[:space:]]+(-d|--decode)[^|]*\|[[:space:]]*(sh|bash)' 2>/dev/null; then
  _vibestack_log careful ask shell-obfuscation "$CMD"
  _vibestack_analytics ask shell_obfuscation
  vibe_hook_decision ask "[careful] Shell obfuscation detected (IFS word-splitting or base64-to-shell). Read the command carefully before approving."
  exit 0
fi

# --- HIGH tier: hard deny (best-effort advisory hard-stop, NOT a policy boundary) ---
# Only SIMPLE commands are eligible: string matching cannot resolve what a
# compound command does (`cd X && git push --force` — whose cwd? which repo?),
# so anything containing ; && || | or a newline falls through to the MEDIUM ask
# families below — conservative failure = ask, never guess.
# --force-with-lease is deliberately NOT matched here (it is the safe variant).
_IS_SIMPLE=1
case "$CMD" in
  *';'*|*'&&'*|*'||'*|*'|'*|*$'\n'*) _IS_SIMPLE=0 ;;
esac
if [ "$_IS_SIMPLE" -eq 1 ]; then
  # Recursive delete aimed at the filesystem root or the whole home directory.
  # Tokenized: options (long or short, any position — --no-preserve-root may
  # trail the target) are skipped; EVERY non-option token must be a root-class
  # target (/, ~, $HOME, /*), and a recursive flag must be present. noglob is
  # forced around word-splitting so a literal /* token never expands.
  if printf '%s' "$CMD" | grep -qE '^[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]' 2>/dev/null \
    && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)' 2>/dev/null; then
    _ROOT_TARGETS=0
    _SAFE_TARGETS=0
    set -f
    for _TOK in $CMD; do
      # Strip one layer of surrounding quotes: rm -rf "/" is still rm -rf /.
      _TOK="${_TOK#\"}"; _TOK="${_TOK%\"}"; _TOK="${_TOK#\'}"; _TOK="${_TOK%\'}"
      case "$_TOK" in
        # Skip non-target decoration: options, `--`, redirections (2>/dev/null
        # is the most common suffix on agent-generated commands), backgrounding.
        sudo|rm|-*|--|[0-9]'>'*|'>'*|'<'*|'&') continue ;;
        '/'|'~'|'~/'|'$HOME'|'$HOME/'|'${HOME}'|'${HOME}/'|'/*'|'//') _ROOT_TARGETS=1 ;;
        *)
          # `rm -rf /Users/alice` is the same command as `rm -rf ~` when that
          # IS the home directory; matching only the textual forms let the
          # spelled-out path through with an overridable warning.
          _TOK_NOSLASH="${_TOK%/}"
          if [ -n "${HOME:-}" ] && { [ "$_TOK_NOSLASH" = "${HOME%/}" ] || [ "$_TOK_NOSLASH" = "${HOME%/}/*" ]; }; then
            _ROOT_TARGETS=1
          else
            _SAFE_TARGETS=1
          fi
          ;;
      esac
    done
    set +f
    if [ "$_ROOT_TARGETS" -eq 1 ] && [ "$_SAFE_TARGETS" -eq 0 ]; then
      _vibestack_log careful deny high-rm-root "$CMD"
      _vibestack_analytics deny high_rm_root
      vibe_hook_decision deny "[careful][HIGH] Recursive delete of / or the home directory is blocked while /careful is active. If you truly mean it, end the /careful session first."
      exit 0
    fi
  fi
  # Force-push to the repo's default branch (the shared history everyone pulls).
  # Force is carried by -f/--force OR by git's plus-refspec syntax (+main,
  # +HEAD:main) which needs no flag at all. --force-with-lease never matches.
  if printf '%s' "$CMD" | grep -qE '^[[:space:]]*git[[:space:]]+push([[:space:]]|$)' 2>/dev/null; then
    _HAS_FORCE=0
    if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(-f|--force)($|[[:space:]])' 2>/dev/null; then
      _HAS_FORCE=1
    elif printf '%s' "$CMD" | grep -qE '(^|[[:space:]])\+[^[:space:]]' 2>/dev/null; then
      _HAS_FORCE=1
    fi
    if [ "$_HAS_FORCE" -eq 1 ]; then
      # Full branch path (slashed defaults like release/2.0 stay intact) and
      # FIXED-STRING token comparison — never interpolate a branch name into
      # an ERE (metacharacters would over/under-match).
      _DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || true)
      # A fresh clone or a worktree often lacks the origin/HEAD symbolic ref —
      # without a fallback the HIGH tier would be silently inert there. Probe
      # the two conventional defaults.
      if [ -z "$_DEFAULT_BRANCH" ]; then
        if git show-ref --verify -q refs/remotes/origin/main 2>/dev/null; then
          _DEFAULT_BRANCH="main"
        elif git show-ref --verify -q refs/remotes/origin/master 2>/dev/null; then
          _DEFAULT_BRANCH="master"
        fi
      fi
      if [ -n "$_DEFAULT_BRANCH" ]; then
        _TARGETS_DEFAULT=0
        set -f
        for _TOK in $CMD; do
          # Strip one layer of surrounding quotes: `git push -f origin "main"`
          # must not dodge the deny just because the ref is quoted.
          _TOK="${_TOK#\"}"; _TOK="${_TOK%\"}"; _TOK="${_TOK#\'}"; _TOK="${_TOK%\'}"
          case "$_TOK" in git|push|sudo|-*) continue ;; esac
          _REF="${_TOK#+}"          # +main -> main
          _REF="${_REF##*:}"        # HEAD:main / src:main -> main
          _REF="${_REF#refs/heads/}" # refs/heads/main -> main; a fully
                                     # qualified destination is the same push
          if [ "$_REF" = "$_DEFAULT_BRANCH" ]; then
            _TARGETS_DEFAULT=1
            break
          fi
        done
        set +f
        if [ "$_TARGETS_DEFAULT" -eq 0 ] && printf '%s' "$CMD" | grep -qE '^[[:space:]]*git[[:space:]]+push([[:space:]]+(-f|--force))*[[:space:]]*$' 2>/dev/null; then
          # Bare `git push --force` (force flags only, no remote/ref): targets
          # the current branch's upstream — the default branch only when ON it.
          _CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)
          [ -n "$_CURRENT_BRANCH" ] && [ "$_CURRENT_BRANCH" = "$_DEFAULT_BRANCH" ] && _TARGETS_DEFAULT=1
        fi
        if [ "$_TARGETS_DEFAULT" -eq 1 ]; then
          _vibestack_log careful deny high-force-push-default "$CMD"
          _vibestack_analytics deny high_force_push_default
          vibe_hook_decision deny "[careful][HIGH] Force-push to the default branch ($_DEFAULT_BRANCH) is blocked while /careful is active. Use --force-with-lease on a feature branch, or end the /careful session if you truly mean it."
          exit 0
        fi
      fi
    fi
  fi
fi

# Safe exceptions: rm -rf of build artifacts is always allowed.
# Multi-line commands never ride the whitelist — `rm -rf /` on one line and
# `rm -rf node_modules` on the next must not be allowed by the second line.
_SKIP_SAFE_EXCEPTION=0
case "$CMD" in
  *$'\n'*) _SKIP_SAFE_EXCEPTION=1 ;;
esac
if [ "$_SKIP_SAFE_EXCEPTION" -eq 0 ] \
  && printf '%s' "$CMD" | grep -qE 'rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+|--recursive[[:space:]]+)' 2>/dev/null; then
  SAFE_ONLY=true
  # Strip 'rm' and all leading flags; remaining tokens are the target paths
  RM_ARGS=$(printf '%s' "$CMD" | sed -E 's/^[[:space:]]*rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(--[a-z-]+[[:space:]]+)*(--[[:space:]]+)?//')
  set -f
  for target in $RM_ARGS; do
    case "$target" in
      # Command substitution that merely ENDS in a whitelisted suffix
      # (`rm -rf $(./wipe-all)/node_modules`) must not ride the whitelist.
      *'('*|*'`'*)
        SAFE_ONLY=false
        break
        ;;
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
  set +f
  if [ "$SAFE_ONLY" = true ]; then
    _vibestack_log careful allow safe-build-artifact "$CMD"
    echo '{}'
    exit 0
  fi
fi

WARN=""

if printf '%s' "$CMD" | grep -qE 'rm[[:space:]]+(-[a-zA-Z]*[rR]|--recursive)' 2>/dev/null; then
  WARN="Destructive: recursive delete (rm -r). This permanently removes files."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD_LOWER" | grep -qE 'drop[[:space:]]+(table|database)' 2>/dev/null; then
  WARN="Destructive: SQL DROP detected. This permanently deletes database objects."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD_LOWER" | grep -qE '(^|[^[:alnum:]_])truncate([^[:alnum:]_]|$)' 2>/dev/null; then
  WARN="Destructive: SQL TRUNCATE detected. This deletes all rows from a table."
fi

# git carries force either by flag or by a leading + on the refspec (+main,
# +HEAD:refs/heads/main), which needs no flag at all. Matching only the flag
# let the refspec form through with no warning whatsoever.
if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push[[:space:]]+.*(-f([[:space:]]|$)|--force)' 2>/dev/null; then
  WARN="Destructive: git force-push rewrites remote history. Other contributors may lose work."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push[[:space:]]' 2>/dev/null \
  && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])\+[^[:space:]-][^[:space:]]*' 2>/dev/null; then
  WARN="Destructive: git force-push (+refspec) rewrites remote history. Other contributors may lose work."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard' 2>/dev/null; then
  WARN="Destructive: git reset --hard discards all uncommitted changes."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'git[[:space:]]+(checkout|restore)[[:space:]]+\.' 2>/dev/null; then
  WARN="Destructive: discards all uncommitted changes in the working tree."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'kubectl[[:space:]]+delete' 2>/dev/null; then
  WARN="Destructive: kubectl delete removes Kubernetes resources. May impact production."
fi

if [ -z "$WARN" ] && printf '%s' "$CMD" | grep -qE 'docker[[:space:]]+(rm[[:space:]]+-f|system[[:space:]]+prune)' 2>/dev/null; then
  WARN="Destructive: Docker force-remove or prune. May delete running containers or cached images."
fi

if [ -n "$WARN" ]; then
  _vibestack_log careful ask "$WARN" "$CMD"
  _vibestack_analytics ask "$(printf '%s' "$WARN" | cut -d: -f1)"
  vibe_hook_decision ask "[careful] $WARN"
else
  _vibestack_log careful allow no-pattern-match "$CMD"
  echo '{}'
fi
