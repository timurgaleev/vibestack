#!/bin/bash

################################################################################
# lib/config-install.sh — deploys the AI-tool configuration payload.
#
# Sourced by ./install, which owns argument parsing and calls
# config_phase_run(). Nothing here runs at source time.
#
# Targets (payload subdir -> destination):
#   config/claude/ -> ~/.claude/
#   config/kiro/   -> ~/.kiro/
#   config/cursor/ -> ~/.cursor/
#   config/codex/  -> ~/.codex/
#
# Each sync records the files it manages in ~/.local/state/vibekit/manifest_<target>
# and prunes deployed files the repo has since dropped. Files absent from that
# manifest were installed by the user and are never touched. Configuration the
# target app rewrites at runtime (codex/config.toml, codex/rules/default.rules,
# codex/hooks.json, kiro/agents/default.json) — and claude/CLAUDE.md, which
# third-party tools append to — is merged rather than overwritten; see
# lib/config-sync.sh.
#
# The manifest directory and the in-file markers still carry the name the
# config project shipped under. They are frozen on purpose: they identify
# state already written to every installed machine, and renaming them would
# orphan that state and duplicate managed blocks on the next sync.
#
# Behaviour is driven by the module globals below, which ./install sets before
# calling: PREVIEW_ONLY, CAVEMAN, PONYTAIL, DELIBERATION, RTK, PAYLOAD_DIR,
# CFG_REPO_DIR.
#
# Environment variables (read here, documented for ./install --help):
#   CAVEMAN_INSTALL_URL=<url>   Override the Caveman installer source
#   PONYTAIL_REPO=<owner/repo>  Override the Ponytail marketplace source
#   DELIBERATION_REPO=<o/r>     Override the deliberation marketplace source
#   RTK_VERSION=vX.Y.Z          Pin an RTK release (default: latest)
#   RTK_INSTALL_URL=<url>       Override the RTK installer source
#   RTK_INSTALL_DIR=<dir>       Install dir passed to RTK (default ~/.local/bin)
#
# Caveman (https://github.com/JuliusBrussee/caveman) compresses agent output.
# Off by default; it self-updates via its own installer, which is pinned to a
# commit SHA here so enabling it never silently runs whatever landed upstream.
#
# Ponytail (https://github.com/DietrichGebert/ponytail) steers the agent toward
# minimal, stdlib-first code. Off by default, installed via the `claude plugin`
# CLI, which tracks the marketplace repo's default branch — no SHA pin.
#
# deliberation (https://github.com/antonbabenko/deliberation) delegates a second
# opinion to another model over MCP. Off by default. Only the plugin is
# installed: its own `/deliberation:setup` writes the rules and config, and this
# installer never runs it, never touches that config, and never stores a
# provider key. Those rules load in every session and cost roughly 12k tokens,
# so setup stays a deliberate, manual step.
#
# RTK (https://github.com/rtk-ai/rtk) compresses shell-command output before it
# reaches the model. On by default; idempotent — if `rtk` is already on PATH the
# download is skipped and only the Claude Code hook is refreshed. `rtk init -g`
# writes a PreToolUse hook into ~/.claude/settings.json, so it runs after the
# settings merge and survives every sync. See SECURITY.md for the trust model.
################################################################################

# Sourced by ./install — this file writes nothing at source time; every effect
# lives in config_phase_run().
#
# Deliberately no `set -e`. The caller runs under `set -uo pipefail` with
# errexit off, and its rollback paths depend on that: a failing `rm -rf` or a
# `mv` of an absent backup must not abort the run. Commands whose failure
# matters are checked here instead.
CFG_REPO_DIR="${CFG_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# The deployable payload; the repo root stays separate because the sync library
# is resolved from it.
PAYLOAD_DIR="${PAYLOAD_DIR:-$CFG_REPO_DIR/config}"

# Targets this run may write to, space separated. Empty means every target in
# DEPLOY_TARGETS — ./install always passes the resolved list, so `--target=codex`
# no longer rewrites Claude, Cursor and Kiro configuration on the way past.
CFG_TARGETS="${CFG_TARGETS:-}"

cfg_target_selected() {
  [[ -z "$CFG_TARGETS" ]] && return 0
  local t
  for t in $CFG_TARGETS; do
    [[ "$t" == "$1" ]] && return 0
  done
  return 1
}

DEPLOY_TARGETS=(
  "claude:${HOME}/.claude"
  "kiro:${HOME}/.kiro"
  "cursor:${HOME}/.cursor"
  "codex:${HOME}/.codex"
)

PREVIEW_ONLY=false
CAVEMAN=${CAVEMAN:-false}      # Set to true or use -C flag to install the Caveman skill
# Pinned to a specific commit (not `main`) so enabling -C never silently runs
# whatever lands upstream. Review the upstream diff before bumping this SHA.
# Override with CAVEMAN_INSTALL_URL=<url> to use latest main, a fork, or a mirror.
CAVEMAN_INSTALL_URL=${CAVEMAN_INSTALL_URL:-https://raw.githubusercontent.com/JuliusBrussee/caveman/25d22f864ad68cc447a4cb93aefde918aa4aec9f/install.sh}
PONYTAIL=${PONYTAIL:-false}    # Set to true or use -Y flag to install the Ponytail plugin
PONYTAIL_REPO=${PONYTAIL_REPO:-DietrichGebert/ponytail}  # Marketplace source (owner/repo, URL, or path)
PONYTAIL_PLUGIN=${PONYTAIL_PLUGIN:-ponytail@ponytail}     # plugin@marketplace identifier
DELIBERATION=${DELIBERATION:-false}  # Set to true or use -D flag to install the deliberation plugin
DELIBERATION_REPO=${DELIBERATION_REPO:-antonbabenko/agent-plugins}  # Marketplace source (owner/repo, URL, or path)
DELIBERATION_PLUGIN=${DELIBERATION_PLUGIN:-deliberation@antonbabenko}  # plugin@marketplace identifier
RTK=${RTK:-true}               # Set to false or use -R flag to skip RTK install
# Tracks the latest tagged release; the installer verifies SHA-256 checksums.
# Pin with RTK_VERSION=vX.Y.Z, or point RTK_INSTALL_URL at a fork/mirror/pinned ref.
RTK_INSTALL_URL=${RTK_INSTALL_URL:-https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh}
RTK_VERSION=${RTK_VERSION:-}    # Empty = latest release; set e.g. v0.43.0 to pin

# Files co-owned with the target app: the repo contributes some entries, the app
# writes the rest at runtime. Declared statically as target:relpath:strategy.
#
# This list is the single source for two things — which merge strategy a file
# gets, and which paths prune must never delete. Deriving the protected set from
# the files actually present in the repo would drop protection at exactly the
# moment it is needed: the release that stops shipping one of these.
MERGE_MANAGED=(
  "claude:CLAUDE.md:append"
  "codex:config.toml:toml"
  "codex:hooks.json:json"
  "cursor:hooks.json:json"
  "codex:rules/default.rules:block"
  "kiro:agents/default.json:json"
)

# merge_strategy_for <target> <relpath> — echoes the strategy, or nothing.
merge_strategy_for() {
  local entry
  for entry in "${MERGE_MANAGED[@]}"; do
    if [[ "${entry%%:*}" == "$1" && "$(echo "$entry" | cut -d: -f2)" == "$2" ]]; then
      printf '%s' "${entry##*:}"
      return 0
    fi
  done
}

# ~/.claude/CLAUDE.md is repo-managed down to this line; `rtk init` and anything
# else that wants to be loaded appends below it, and stays there across syncs.
CLAUDE_MD_END="<!-- END vibekit-managed CLAUDE.md — lines below are yours and survive every sync -->"

# Codex rewrites ~/.codex/rules/default.rules whenever the user approves a
# command prefix, so only the region between these markers is repo-managed.
CODEX_RULES_BEGIN="# BEGIN vibekit managed codex rules"
CODEX_RULES_END="# END vibekit managed codex rules"

# Counters
ADDED=0
CHANGED=0
SKIPPED=0
PRUNED=0
FAILED=0

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

msg_info()  { echo -e "${BLUE}  > $*${NC}"; }
msg_done()  { echo -e "${GREEN}  + $*${NC}"; }
msg_add()   { echo -e "${CYAN}  * $*${NC}"; }
msg_warn()  { echo -e "${YELLOW}  ! $*${NC}"; }

file_hash() {
  if [[ "$(uname)" == "Darwin" ]]; then
    md5 -q "$1" 2>/dev/null
  else
    md5sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

is_bin() {
  file "$1" | grep -qv "text"
}


# cfg_write_file <dst> <content> — write through the atomic helper when the sync
# library is loaded, so a failed or short write cannot truncate a destination
# the user already had.
cfg_write_file() {
  local dst="$1" content="$2"
  if declare -f write_atomic >/dev/null 2>&1; then
    printf '%s\n' "$content" | write_atomic "$dst"
  else
    printf '%s\n' "$content" > "$dst"
  fi
}

# Returns non-zero on failure and says so. Without errexit a silent `cp`
# failure would be reported as a successful UPDATE and then recorded in the
# manifest, which is how a file the sync never wrote becomes prunable.
deploy_file() {
  local src="$1" dst="$2"
  if ! mkdir -p "$(dirname "$dst")" 2>/dev/null; then
    msg_warn "could not create $(dirname "$dst")"
    return 1
  fi
  if ! cp "$src" "$dst" 2>/dev/null; then
    msg_warn "could not write $dst"
    return 1
  fi
}

diff_preview() {
  local src="$1" dst="$2"

  if command -v colordiff >/dev/null 2>&1; then
    diff -u "$dst" "$src" | colordiff | head -30
  else
    diff -u "$dst" "$src" | head -30
  fi

  local total
  total=$(diff -u "$dst" "$src" | wc -l)
  if [[ $total -gt 30 ]]; then
    msg_warn "... (${total} lines total, showing first 30)"
  fi
}



# Sync helpers: manifest-based prune plus the fill-missing merges used for files
# the target app rewrites at runtime. Without this lib the deploy still works,
# it just stops pruning files the repo has dropped.
SYNC_LIB_LOADED=false
if [[ -f "$CFG_REPO_DIR/lib/config-sync.sh" ]]; then
  source "$CFG_REPO_DIR/lib/config-sync.sh"
  SYNC_LIB_LOADED=true
else
  msg_warn "lib/config-sync.sh missing in $CFG_REPO_DIR — prune and fill-missing merges unavailable"
fi

# Sweeps the temps staged beside their destinations. Without it an interrupt
# mid-merge leaves e.g. ~/.claude/CLAUDE.md.vibekit.a1b2c3 next to the real
# file, in a directory the agent reads.
config_cleanup_tmps() {
  local f
  for f in "${CFG_TMP_FILES[@]:-}"; do
    [[ -n "$f" ]] && rm -f "$f"
  done
  CFG_TMP_FILES=()
}

# config_phase_run — deploy the payload into every target present on this
# machine. Returns 0 when every target applied, 1 when any target was refused
# or failed; the caller reports both without aborting the other phase.
#
# The body below is deliberately not re-indented. Keeping it flush left leaves
# the diff against the standalone installer it came from reviewable.
config_phase_run() {
# The body below is flush-left, so without this every working name would land
# in the caller's scope. Nothing collides today; this keeps it that way when
# ./install grows a variable of its own called rc, merged or root.
local entry mm_entry src_subdir dst_dir src_path rel_path dst_file src_file
local merge_mode rc src_hash dst_hash manifest_tmp protected_tmp find_excludes
local list_tmp find_status
local legacy want_hash got_hash merged merged_hash node_major
local rtk_dir rtk_bin rtk_installer target_failed

ADDED=0; CHANGED=0; SKIPPED=0; PRUNED=0; FAILED=0
CFG_TMP_FILES=()
# ./install's INT and TERM handlers call exit, so EXIT covers an interrupt too.
trap config_cleanup_tmps EXIT

echo -e "\n${CYAN}---------------------------------------------------------------${NC}"
echo -e "${CYAN}                     AI-CONFIG DEPLOY                         ${NC}"
echo -e "${CYAN}---------------------------------------------------------------${NC}"

if [[ "$PREVIEW_ONLY" == true ]]; then
  msg_warn "Preview mode: no files will be written"
fi

if [[ "$CAVEMAN" == true ]]; then
  msg_info "Caveman skill: will install (-C)"
else
  msg_info "Caveman skill: skipped (default — pass -C to install)"
fi

if [[ "$PONYTAIL" == true ]]; then
  msg_info "Ponytail plugin: will install (-Y)"
else
  msg_info "Ponytail plugin: skipped (default — pass -Y to install)"
fi

if [[ "$DELIBERATION" == true ]]; then
  msg_info "deliberation plugin: will install (-D)"
else
  msg_info "deliberation plugin: skipped (default — pass -D to install)"
fi

if [[ "$RTK" == true ]]; then
  msg_info "RTK: will install/refresh (default — pass -R to skip)"
else
  msg_info "RTK: skipped (-R)"
fi


# One-time cleanup of files earlier versions deployed before manifests existed,
# so a machine that never had a manifest still loses them. Without a manifest
# there is no ownership record, so each entry pairs a path with the SHA-256 of
# the exact bytes this repo shipped (recovered from the removal commit). Only a
# byte-identical file is deleted: any local edit, however small, means the user
# has taken it over.
# NOTE: drop this block once every machine has synced past v1.6.0.
LEGACY_FILES=(
  # Replaced by rules/memex.md in v1.5.4 (commit 4f424a6).
  "${HOME}/.claude/rules/obsidian.md|627b1a56232c9b58a5aa5476e6db40440ea73cdb496f40f7be87d103392efb98"
  "${HOME}/.cursor/rules/obsidian.mdc|9cb8671e4c1b82341c7e1cea6212e2c5fd5875ec7cbd4a958b66ec34521567d3"
)
for entry in "${LEGACY_FILES[@]}"; do
  legacy="${entry%%|*}"
  want_hash="${entry#*|}"
  [[ -f "$legacy" ]] || continue
  got_hash=$(shasum -a 256 "$legacy" 2>/dev/null | awk '{print $1}')
  if [[ "$got_hash" != "$want_hash" ]]; then
    msg_warn "KEEPING ${legacy/#$HOME/\~} — differs from the version vibekit shipped; delete it yourself if unwanted"
    continue
  fi
  msg_warn "REMOVE (legacy): ${legacy/#$HOME/\~}"
  [[ "$PREVIEW_ONLY" == false ]] && rm -f "$legacy"
done

# Deploy each target
for entry in "${DEPLOY_TARGETS[@]}"; do
  src_subdir="${entry%%:*}"
  dst_dir="${entry#*:}"

  cfg_target_selected "$src_subdir" || continue
  src_path="$PAYLOAD_DIR/$src_subdir"

  if [[ ! -d "$src_path" ]] || [[ -z "$(ls -A "$src_path" 2>/dev/null)" ]]; then
    msg_info "Skipping $src_subdir/ (empty or missing)"
    continue
  fi

  echo -e "\n${CYAN}> Deploying $src_subdir/ -> $dst_dir/${NC}"

  if [[ ! -d "$dst_dir" ]] && [[ "$PREVIEW_ONLY" == false ]]; then
    mkdir -p "$dst_dir"
  fi

  # claude/settings.json is merged separately below to preserve user customizations
  # (locally-enabled plugins, additions to permissions.allow, etc.), so it is
  # also left out of the manifest and never pruned.
  find_excludes=(
    "-not" "-path" "*/.git/*"
    "-not" "-path" "*/__pycache__/*"
    "-not" "-name" "*.pyc"
    "-not" "-name" "cli-config.json"
  )
  if [[ "$src_subdir" == "claude" ]]; then
    find_excludes+=("-not" "-name" "settings.json")
  fi

  # A failed write aborts this target. The manifest entry for a file is
  # written before the file is deployed, so committing a manifest after a
  # failed write would claim a file that is not on disk — and a later run
  # would prune against that claim.
  target_failed=false

  # Records every file this run manages, deployed or already identical. The
  # diff against the previous run is what prune acts on.
  if ! manifest_tmp="$(mktemp)"; then
    msg_warn "$src_subdir: could not stage a manifest — skipping this target"
    FAILED=$((FAILED + 1))
    continue
  fi
  CFG_TMP_FILES+=("$manifest_tmp")
  # Paths this sync co-owns with the target app, taken from the static
  # declaration rather than from what the repo currently ships — so prune keeps
  # skipping them even after a release stops shipping one.
  if ! protected_tmp="$(mktemp)"; then
    msg_warn "$src_subdir: could not stage the protected list — skipping this target"
    FAILED=$((FAILED + 1))
    rm -f "$manifest_tmp"
    continue
  fi
  CFG_TMP_FILES+=("$protected_tmp")
  for mm_entry in "${MERGE_MANAGED[@]}"; do
    [[ "${mm_entry%%:*}" == "$src_subdir" ]] && echo "$mm_entry" | cut -d: -f2 >> "$protected_tmp"
  done

  if ! list_tmp="$(mktemp)"; then
    msg_warn "$src_subdir: could not stage the file list — skipping this target"
    FAILED=$((FAILED + 1))
    rm -f "$manifest_tmp" "$protected_tmp"
    continue
  fi
  CFG_TMP_FILES+=("$list_tmp")
  find "$src_path" -type f "${find_excludes[@]}" -print0 | sort -z > "$list_tmp"
  find_status=("${PIPESTATUS[@]}")
  if [[ "${find_status[0]}" -ne 0 || "${find_status[1]}" -ne 0 ]]; then
    msg_warn "$src_subdir: could not list the payload (find/sort failed) — skipping this target"
    FAILED=$((FAILED + 1))
    rm -f "$manifest_tmp" "$protected_tmp" "$list_tmp"
    continue
  fi

  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#$src_path/}"
    dst_file="$dst_dir/$rel_path"

    # The manifest is newline-delimited; a filename containing a newline would
    # split into entries that prune later matches against unrelated files.
    if [[ "$rel_path" == *$'\n'* ]]; then
      msg_warn "SKIP: filename contains a newline — $(printf '%q' "$rel_path")"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    # Files a second writer owns part of (Codex project trust and TUI state,
    # Codex's accepted command prefixes, Kiro's agent hooks, the `@RTK.md` line
    # `rtk init` appends to Claude's CLAUDE.md) are merged instead of
    # overwritten, so that writer's state survives every sync.
    merge_mode="$(merge_strategy_for "$src_subdir" "$rel_path")"

    # Merge-managed files are co-owned: the repo contributes some keys, the app
    # writes the rest. They are deliberately kept OUT of the manifest — if the
    # repo ever stopped shipping one, pruning it would delete the user's runtime
    # state along with our entries. Everything else is manifest-tracked and
    # therefore prunable.
    if [[ -z "$merge_mode" ]]; then
      if ! printf '%s\n' "$rel_path" >> "$manifest_tmp"; then
        msg_warn "$src_subdir: could not record $rel_path — aborting before prune"
        target_failed=true
        break
      fi
    else
      if ! printf '%s\n' "$rel_path" >> "$protected_tmp"; then
        msg_warn "$src_subdir: could not protect $rel_path — aborting before prune"
        target_failed=true
        break
      fi
    fi

    # Without the merge helpers a plain copy would wipe the runtime state these
    # files hold, so skip them rather than overwrite.
    if [[ -n "$merge_mode" && "$SYNC_LIB_LOADED" == false ]]; then
      msg_warn "SKIP: $rel_path (needs lib/sync.sh to merge safely)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    if [[ -n "$merge_mode" ]]; then
      rc=0
      case "$merge_mode" in
        toml)  toml_fill_missing "$src_file" "$dst_file" || rc=$? ;;
        json)  json_fill_missing "$src_file" "$dst_file" || rc=$? ;;
        block) sync_managed_block "$src_file" "$dst_file" \
                 "$CODEX_RULES_BEGIN" "$CODEX_RULES_END" || rc=$? ;;
        append) sync_append_managed "$src_file" "$dst_file" "$CLAUDE_MD_END" || rc=$? ;;
      esac
      case "$rc" in
        0) SKIPPED=$((SKIPPED + 1)) ;;
        1) msg_done "MERGE: $rel_path (added missing entries, kept local ones)"
           CHANGED=$((CHANGED + 1)) ;;
        2) msg_add  "NEW: $rel_path"
           ADDED=$((ADDED + 1)) ;;
      esac
      continue
    fi

    if [[ ! -f "$dst_file" ]]; then
      msg_add "NEW: $rel_path"
      if [[ "$PREVIEW_ONLY" == false ]]; then
        if ! deploy_file "$src_file" "$dst_file"; then
          target_failed=true
          break
        fi
      fi
      ADDED=$((ADDED + 1))
    else
      src_hash=$(file_hash "$src_file")
      dst_hash=$(file_hash "$dst_file")

      if [[ "$src_hash" == "$dst_hash" ]]; then
        SKIPPED=$((SKIPPED + 1))
      else
        msg_done "UPDATE: $rel_path"
        if ! is_bin "$src_file"; then
          diff_preview "$src_file" "$dst_file"
        fi
        if [[ "$PREVIEW_ONLY" == false ]]; then
          if ! deploy_file "$src_file" "$dst_file"; then
            target_failed=true
            break
          fi
        fi
        CHANGED=$((CHANGED + 1))
      fi
    fi
  done < "$list_tmp"

  # Prune files a previous sync deployed that the repo no longer ships. Files
  # absent from the previous manifest were installed by the user and are left
  # alone.
  if [[ "$target_failed" == true ]]; then
    msg_warn "$src_subdir: deploy failed — manifest not updated, nothing pruned"
    FAILED=$((FAILED + 1))
    rm -f "$manifest_tmp"
  elif [[ "$SYNC_LIB_LOADED" == true ]]; then
    if ! prune_target "$src_subdir" "$dst_dir" "$manifest_tmp" "$protected_tmp"; then
      msg_warn "$src_subdir: prune failed"
      FAILED=$((FAILED + 1))
    fi
    PRUNED=$((PRUNED + PRUNE_COUNT))
    # A manifest that did not land means the next run prunes against a stale
    # list, so this is reported rather than swallowed.
    if ! commit_manifest "$src_subdir" "$manifest_tmp"; then
      msg_warn "$src_subdir: could not record the manifest — the next run will prune against the previous one"
      FAILED=$((FAILED + 1))
    fi
  else
    rm -f "$manifest_tmp"
  fi
  rm -f "$protected_tmp"
done

# Claude settings.json: deep merge so user customizations survive sync.
#   - Source wins for scalar/object keys (repo authoritative for shared policy)
#   - permissions.allow/deny/ask/additionalDirectories: array union (user additions kept)
#   - enabledPlugins: deep merge (user-enabled plugins not in repo preserved)
#   - Destination-only top-level keys preserved (e.g. user-set skipAutoPermissionPrompt)
if cfg_target_selected claude; then
CLAUDE_SETTINGS_SRC="$PAYLOAD_DIR/claude/settings.json"
CLAUDE_SETTINGS_DST="${HOME}/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS_SRC" ]]; then
  echo -e "\n${CYAN}> Merging claude/settings.json -> $CLAUDE_SETTINGS_DST${NC}"
  if [[ ! -f "$CLAUDE_SETTINGS_DST" ]]; then
    msg_add "NEW: claude/settings.json"
    if [[ "$PREVIEW_ONLY" == false ]]; then
      deploy_file "$CLAUDE_SETTINGS_SRC" "$CLAUDE_SETTINGS_DST"
    fi
    ADDED=$((ADDED + 1))
  elif command -v python3 >/dev/null 2>&1; then
    merged=$(python3 - "$CLAUDE_SETTINGS_SRC" "$CLAUDE_SETTINGS_DST" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    src = json.load(f)
with open(sys.argv[2]) as f:
    dst = json.load(f)

PERMISSION_ARRAY_KEYS = ("allow", "deny", "ask", "additionalDirectories")

def deep_merge(s, d):
    if not isinstance(s, dict) or not isinstance(d, dict):
        return s
    out = dict(d)
    for k, v in s.items():
        if k in d and isinstance(v, dict) and isinstance(d[k], dict):
            out[k] = deep_merge(v, d[k])
        else:
            out[k] = v
    return out

def union_dedup(*arrays):
    seen = set()
    result = []
    for arr in arrays:
        if not isinstance(arr, list):
            continue
        for item in arr:
            key = item if isinstance(item, (str, int, float, bool, type(None))) else repr(item)
            if key in seen:
                continue
            seen.add(key)
            result.append(item)
    return result

merged = deep_merge(src, dst)

if isinstance(src.get("permissions"), dict) and isinstance(dst.get("permissions"), dict):
    merged.setdefault("permissions", {})
    for k in PERMISSION_ARRAY_KEYS:
        s_list = src["permissions"].get(k)
        d_list = dst["permissions"].get(k)
        if isinstance(s_list, list) or isinstance(d_list, list):
            merged["permissions"][k] = union_dedup(s_list or [], d_list or [])

print(json.dumps(merged, indent=2))
PYEOF
) || merged=""
    # An unreadable or malformed file makes the merge program exit non-zero with
    # nothing on stdout. Writing that would replace the user's settings with a
    # blank line, so the result is validated before it is allowed anywhere near
    # the destination.
    if [[ -z "$merged" ]] || ! printf '%s\n' "$merged" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      msg_warn "claude/settings.json: merge failed — leaving the existing file untouched"
      FAILED=$((FAILED + 1))
    else
      merged_hash=$(printf '%s\n' "$merged" | md5 -q 2>/dev/null || printf '%s\n' "$merged" | md5sum | awk '{print $1}')
      dst_hash=$(file_hash "$CLAUDE_SETTINGS_DST")
      if [[ "$merged_hash" != "$dst_hash" ]]; then
        msg_done "MERGE: claude/settings.json (preserved user customizations)"
        if [[ "$PREVIEW_ONLY" == false ]]; then
          if ! cfg_write_file "$CLAUDE_SETTINGS_DST" "$merged"; then
            msg_warn "claude/settings.json: could not write $CLAUDE_SETTINGS_DST"
            FAILED=$((FAILED + 1))
          else
            CHANGED=$((CHANGED + 1))
          fi
        else
          CHANGED=$((CHANGED + 1))
        fi
      else
        msg_info "no changes after merge"
        SKIPPED=$((SKIPPED + 1))
      fi
    fi
  else
    # The old behaviour here was a full overwrite, which silently discarded
    # every customization the merge exists to preserve. Refusing is the only
    # honest answer when the tool that does the preserving is missing.
    msg_warn "claude/settings.json: python3 not found — refusing to replace it (the merge needs python3)"
    FAILED=$((FAILED + 1))
  fi
fi

fi

# Cursor cli-config.json: merge only non-personal keys (permissions, approvalMode)
# to avoid overwriting personal data (authInfo, model, etc.)
if cfg_target_selected cursor; then
CURSOR_CLI_CONFIG_SRC="$PAYLOAD_DIR/cursor/cli-config.json"
CURSOR_CLI_CONFIG_DST="${HOME}/.cursor/cli-config.json"
if [[ -f "$CURSOR_CLI_CONFIG_SRC" ]]; then
  if [[ ! -f "$CURSOR_CLI_CONFIG_DST" ]]; then
    msg_add "NEW: cursor/cli-config.json"
    if [[ "$PREVIEW_ONLY" == false ]]; then
      deploy_file "$CURSOR_CLI_CONFIG_SRC" "$CURSOR_CLI_CONFIG_DST"
    fi
    ADDED=$((ADDED + 1))
  else
    if command -v python3 >/dev/null 2>&1; then
      merged=$(python3 - "$CURSOR_CLI_CONFIG_SRC" "$CURSOR_CLI_CONFIG_DST" <<'PYEOF'
import json, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2]))
for key in ("permissions", "approvalMode", "version"):
    if key in src:
        dst[key] = src[key]
print(json.dumps(dst, indent=2))
PYEOF
) || merged=""
      # Same guard as the Claude settings merge: a failed program prints
      # nothing, and writing that would replace the file — which here holds the
      # user's Cursor credentials and model choice — with a blank line.
      if [[ -z "$merged" ]] || ! printf '%s\n' "$merged" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        msg_warn "cursor/cli-config.json: merge failed — leaving the existing file untouched"
        FAILED=$((FAILED + 1))
        merged_hash=""
        dst_hash=""
      else
      merged_hash=$(printf '%s\n' "$merged" | md5 -q 2>/dev/null || printf '%s\n' "$merged" | md5sum | awk '{print $1}')
      dst_hash=$(file_hash "$CURSOR_CLI_CONFIG_DST")
      if [[ "$merged_hash" != "$dst_hash" ]]; then
        msg_done "MERGE: cursor/cli-config.json (permissions, approvalMode)"
        if [[ "$PREVIEW_ONLY" == false ]]; then
          if ! cfg_write_file "$CURSOR_CLI_CONFIG_DST" "$merged"; then
            msg_warn "cursor/cli-config.json: could not write $CURSOR_CLI_CONFIG_DST"
            FAILED=$((FAILED + 1))
          fi
        fi
        CHANGED=$((CHANGED + 1))
      else
        SKIPPED=$((SKIPPED + 1))
      fi
      fi
    else
      msg_warn "python3 not found — skipping cursor/cli-config.json merge"
    fi
  fi
fi

fi

# Cursor settings.json requires a manual step (different path per OS)
if cfg_target_selected cursor; then
CURSOR_SETTINGS_SRC="$PAYLOAD_DIR/cursor/settings.json"
if [[ -f "$CURSOR_SETTINGS_SRC" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    CURSOR_SETTINGS_DST="$HOME/Library/Application Support/Cursor/User/settings.json"
  else
    CURSOR_SETTINGS_DST="$HOME/.config/Cursor/User/settings.json"
  fi
  if [[ ! -f "$CURSOR_SETTINGS_DST" ]]; then
    msg_add "NOTE: Cursor settings.json not applied automatically."
    msg_info "  To apply: cp \"$CURSOR_SETTINGS_SRC\" \"$CURSOR_SETTINGS_DST\""
  else
    src_hash=$(file_hash "$CURSOR_SETTINGS_SRC")
    dst_hash=$(file_hash "$CURSOR_SETTINGS_DST")
    if [[ "$src_hash" != "$dst_hash" ]]; then
      msg_warn "Cursor settings.json has changes — merge manually:"
      msg_info "  Source:      $CURSOR_SETTINGS_SRC"
      msg_info "  Destination: $CURSOR_SETTINGS_DST"
    fi
  fi
fi

fi

# Caveman skill: opt-in install via its official installer (self-updating).
# Off by default; enabled with -C or CAVEMAN=true. Requires Node >= 18 — if it
# is missing we warn and skip rather than aborting the whole sync.
if [[ "$CAVEMAN" == true ]]; then
  echo -e "\n${CYAN}> Installing Caveman skill...${NC}"

  node_major=""
  if command -v node >/dev/null 2>&1; then
    node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo "")
  fi

  if [[ -z "$node_major" ]]; then
    msg_warn "Node not found — skipping Caveman (needs Node >= 18)"
    msg_info "Install Node, then re-run: $0 -C"
  elif [[ "$node_major" -lt 18 ]]; then
    msg_warn "Node $(node -v 2>/dev/null) is too old — skipping Caveman (needs Node >= 18)"
    msg_info "Upgrade Node, then re-run: $0 -C"
  elif [[ "$PREVIEW_ONLY" == true ]]; then
    msg_warn "Preview mode: would run Caveman installer:"
    msg_info "  curl -fsSL \"$CAVEMAN_INSTALL_URL\" | bash"
  else
    msg_info "Running Caveman installer: $CAVEMAN_INSTALL_URL"
    if curl -fsSL "$CAVEMAN_INSTALL_URL" | bash; then
      msg_done "Caveman installed"
    else
      msg_warn "Caveman installer failed — skipping (sync continues)"
    fi
  fi
fi

# Ponytail plugin: opt-in install via the official `claude plugin` CLI.
# Off by default; enabled with -Y or PONYTAIL=true. Needs the `claude` CLI — if
# it is missing we warn and skip rather than aborting the whole sync. The
# marketplace add is idempotent: a second run reports "already added".
if [[ "$PONYTAIL" == true ]]; then
  echo -e "\n${CYAN}> Installing Ponytail plugin...${NC}"

  if ! command -v claude >/dev/null 2>&1; then
    msg_warn "claude CLI not found — skipping Ponytail"
    msg_info "Install Claude Code, then re-run: $0 -Y"
  elif [[ "$PREVIEW_ONLY" == true ]]; then
    msg_warn "Preview mode: would install Ponytail plugin:"
    msg_info "  claude plugin marketplace add $PONYTAIL_REPO"
    msg_info "  claude plugin install $PONYTAIL_PLUGIN"
  else
    msg_info "Adding marketplace: $PONYTAIL_REPO"
    if ! claude plugin marketplace add "$PONYTAIL_REPO" 2>/dev/null; then
      msg_info "Marketplace already added (or could not be re-added)"
    fi
    if claude plugin install "$PONYTAIL_PLUGIN"; then
      msg_done "Ponytail installed (restart Claude Code to load it)"
    else
      msg_warn "Ponytail install failed — skipping (sync continues)"
    fi
  fi
fi

# deliberation plugin: opt-in install via the official `claude plugin` CLI.
# Off by default; enabled with -D or DELIBERATION=true. Needs the `claude` CLI —
# if it is missing we warn and skip rather than aborting the whole sync.
#
# This installs the plugin and nothing else. The plugin's own
# `/deliberation:setup` owns ~/.claude/rules/deliberation/ and
# ~/.config/deliberation/config.json; running it from here would add ~12k tokens
# of always-on rules and could enable a paid provider behind the user's back.
if [[ "$DELIBERATION" == true ]]; then
  echo -e "\n${CYAN}> Installing deliberation plugin...${NC}"

  if ! command -v claude >/dev/null 2>&1; then
    msg_warn "claude CLI not found — skipping deliberation"
    msg_info "Install Claude Code, then re-run: $0 -D"
  elif [[ "$PREVIEW_ONLY" == true ]]; then
    msg_warn "Preview mode: would install deliberation plugin:"
    msg_info "  claude plugin marketplace add $DELIBERATION_REPO"
    msg_info "  claude plugin install $DELIBERATION_PLUGIN"
  else
    msg_info "Adding marketplace: $DELIBERATION_REPO"
    if ! claude plugin marketplace add "$DELIBERATION_REPO" 2>/dev/null; then
      msg_info "Marketplace already added (or could not be re-added)"
    fi
    if claude plugin install "$DELIBERATION_PLUGIN"; then
      msg_done "deliberation installed (restart Claude Code to load it)"
      msg_info "Configuration is a separate, manual step — run /deliberation:setup"
      msg_info "  it installs ~12k tokens of rules loaded in every session"
      msg_info "  providers need their own auth: codex login, agy, XAI_API_KEY, OPENROUTER_API_KEY"
    else
      msg_warn "deliberation install failed — skipping (sync continues)"
    fi
  fi
fi

# RTK (Rust Token Killer): standalone CLI that compresses shell-command output.
# Installed by default; skip with -R or RTK=false. Idempotent — if `rtk` is
# already on PATH the binary download is skipped and only the hook is refreshed.
#
# `rtk init -g` adds a PreToolUse hook to ~/.claude/settings.json. The settings
# merge above is repo-authoritative for the hooks map, so init MUST run here
# (after the merge) to re-apply the RTK hook on every sync instead of having it
# clobbered. If the installer or init fails we warn and continue the sync.
#
# Gated on the claude target for the same reason: `rtk init -g` writes into
# ~/.claude/settings.json, so a run that excluded Claude must not reach it.
if [[ "$RTK" == true ]] && cfg_target_selected claude; then
  echo -e "\n${CYAN}> Installing RTK...${NC}"

  # Honor the upstream installer's RTK_INSTALL_DIR so a binary placed off-PATH
  # is still found for `rtk init -g`; default matches the installer's own default.
  rtk_dir="${RTK_INSTALL_DIR:-${HOME}/.local/bin}"
  rtk_bin="$(command -v rtk 2>/dev/null || true)"
  if [[ -z "$rtk_bin" && -x "${rtk_dir}/rtk" ]]; then
    rtk_bin="${rtk_dir}/rtk"
  fi

  if [[ -n "$rtk_bin" ]]; then
    msg_info "RTK already installed ($("$rtk_bin" --version 2>/dev/null || echo present)) — skipping binary install"
  elif [[ "$PREVIEW_ONLY" == true ]]; then
    msg_warn "Preview mode: would install RTK:"
    msg_info "  curl -fsSL \"$RTK_INSTALL_URL\" | sh"
  else
    msg_info "Running RTK installer: $RTK_INSTALL_URL"
    [[ -n "$RTK_VERSION" ]] && msg_info "Pinned version: $RTK_VERSION"
    # Download to a temp file first: `curl | sh` reports the shell's exit status,
    # not curl's (no pipefail here), so a failed download would look like success.
    rtk_installer="$(mktemp)"
    if curl -fsSL "$RTK_INSTALL_URL" -o "$rtk_installer" && RTK_VERSION="$RTK_VERSION" sh "$rtk_installer"; then
      msg_done "RTK installed"
      rtk_bin="$(command -v rtk 2>/dev/null || true)"
      [[ -z "$rtk_bin" && -x "${rtk_dir}/rtk" ]] && rtk_bin="${rtk_dir}/rtk"
    else
      msg_warn "RTK installer failed — skipping (sync continues)"
    fi
    rm -f "$rtk_installer"
  fi

  # Apply/refresh the Claude Code hook (additive + idempotent). Runs after the
  # settings.json merge so the RTK PreToolUse hook survives each sync.
  # --auto-patch patches settings.json without prompting; </dev/null guards
  # against any stray prompt blocking the curl|bash one-liner on a live TTY.
  if [[ -n "$rtk_bin" ]]; then
    if [[ "$PREVIEW_ONLY" == true ]]; then
      msg_warn "Preview mode: would run: rtk init -g --auto-patch"
    elif "$rtk_bin" init -g --auto-patch </dev/null >/dev/null 2>&1; then
      msg_done "RTK hook applied (restart Claude Code to load it)"
    else
      msg_warn "rtk init failed — hook not applied (sync continues)"
    fi
  fi
fi

# Summary
echo -e "\n${GREEN}---------------------------------------------------------------${NC}"
echo -e "${GREEN}                       DEPLOY COMPLETE                        ${NC}"
echo -e "${GREEN}---------------------------------------------------------------${NC}"
echo
msg_info "Results:"
msg_add  "  New:       $ADDED"
msg_done "  Updated:   $CHANGED"
msg_warn "  Pruned:    $PRUNED"
msg_info "  Unchanged: $SKIPPED"
echo

[[ "$FAILED" -eq 0 ]]
}
