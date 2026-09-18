#!/bin/bash
# lib/sync.sh - deploy-time sync helpers, sourced by install.sh.
#
# Kept in a sourceable lib (not inline in install.sh) so the behavior can be
# unit-tested without running the full deploy flow. install.sh sources this
# file; tests source it directly against a sandboxed HOME.
#
# Provides:
#   retry               - exponential-backoff wrapper for flaky network calls
#   manifest_path       - per-target manifest location
#   prune_target        - delete deployed files that the repo no longer ships
#   json_fill_missing   - add only keys the destination lacks (app-mutated JSON)
#   toml_fill_missing   - same, for flat TOML (app-mutated config.toml)
#   sync_managed_block  - replace only a BEGIN/END marked region of a text file
#   sync_append_managed - repo-owned body + marker; foreign trailing lines kept
#
# Reads the global PREVIEW_ONLY (true => dry-run, print intent, change nothing).

GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[0;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

if ! declare -F msg_info >/dev/null 2>&1; then
  msg_info()  { echo -e "${BLUE}  > $*${NC}"; }
fi
if ! declare -F msg_done >/dev/null 2>&1; then
  msg_done()  { echo -e "${GREEN}  + $*${NC}"; }
fi
if ! declare -F msg_add >/dev/null 2>&1; then
  msg_add()   { echo -e "${CYAN}  * $*${NC}"; }
fi
if ! declare -F msg_warn >/dev/null 2>&1; then
  msg_warn()  { echo -e "${YELLOW}  ! $*${NC}"; }
fi

# Manifests record which files *this* sync deployed, per target. They live
# outside REPO_DIR (~/.vibekit) because that directory is a git clone and gets
# reset by `git pull`. XDG state dir rather than a new dotdir in $HOME.
MANIFEST_DIR="${MANIFEST_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/vibekit}"

# ---------------------------------------------------------------------------
# Safety primitives
# ---------------------------------------------------------------------------

# inside_dir <dir> <path>
# True when <path> physically resolves inside <dir>. The parent chain is
# resolved with `pwd -P`, so a symlinked component cannot smuggle a delete out
# of the deploy target — a lexical `..` check alone does not catch that.
inside_dir() {
  local dir="$1" path="$2" root parent
  root="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
  [[ "$parent" == "$root" || "$parent" == "$root"/* ]]
}

# write_atomic <dst> — content on stdin.
# Writes through a temp file in the destination directory and renames, so a
# failed or short write can never leave a truncated destination behind.
write_atomic() {
  local dst="$1" tmp mode
  tmp="$(mktemp "${dst}.vibekit.XXXXXX")" || return 1
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -f "$dst" ]]; then
    mode="$(stat -f '%Lp' "$dst" 2>/dev/null || stat -c '%a' "$dst" 2>/dev/null || true)"
    [[ -n "$mode" ]] && chmod "$mode" "$tmp"
  fi
  if ! mv -f "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Network resilience
# ---------------------------------------------------------------------------

# retry <description> <command...>
# Three attempts with 5s -> 10s -> 20s backoff. Returns the last exit status.
# install.sh defines its own copy before the clone (which this lib lives in);
# that copy wins when the lib is sourced.
if ! declare -F retry >/dev/null 2>&1; then
retry() {
  local description="$1"
  shift
  local max_retries=3 attempt=0 wait_time=5

  while [[ $attempt -lt $max_retries ]]; do
    if "$@"; then
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ $attempt -eq $max_retries ]]; then
      return 1
    fi
    msg_warn "$description failed — retrying in ${wait_time}s (attempt $attempt/$max_retries)"
    sleep "$wait_time"
    wait_time=$((wait_time * 2))
  done
}
fi

# create_from <src> <dst>
# First-time deployment of a merge-managed file. Goes through write_atomic so an
# interrupted copy cannot leave a partial config that later syncs would then
# merge into. Returns 2 on success (created), 0 if it could not be written.
create_from() {
  local src="$1" dst="$2"
  [[ "$PREVIEW_ONLY" == true ]] && return 2
  mkdir -p "$(dirname "$dst")" || { msg_warn "Could not create $(dirname "$dst")"; return 0; }
  if ! write_atomic "$dst" < "$src"; then
    msg_warn "Failed to write $dst — not created"
    return 0
  fi
  return 2
}

# ---------------------------------------------------------------------------
# Manifest-based prune
# ---------------------------------------------------------------------------

# manifest_path <target-key>
# Target keys may contain slashes (e.g. "codex/skills"); flatten them.
manifest_path() {
  printf '%s/manifest_%s' "$MANIFEST_DIR" "${1//\//_}"
}

# prune_target <target-key> <dst_dir> <current_manifest_file> [protected_file]
#
# <protected_file> lists paths this sync co-owns with the target app (merged
# key-by-key rather than overwritten). Keeping them out of the *current*
# manifest is not enough: a manifest written before they became merge-managed
# still names them, and prune would read that as "dropped from the repo" and
# delete the user's runtime state. They are skipped unconditionally.
#
# Deletes files that a previous sync deployed but the repo no longer ships.
# Files absent from the previous manifest are user-installed and never touched.
#
# The count comes back in the global PRUNE_COUNT rather than on stdout: this
# function reports each deletion through msg_warn, and a command substitution
# would swallow those lines into the count.
prune_target() {
  local target_key="$1" dst_dir="$2" current="$3" protected="${4:-}"
  local previous
  previous="$(manifest_path "$target_key")"
  PRUNE_COUNT=0

  if [[ ! -f "$previous" ]]; then
    return 0
  fi

  local rel stale parent
  while IFS= read -r rel; do
    # Defend against a corrupted manifest escaping the target directory.
    case "$rel" in
      "" | /* | *..*) continue ;;
    esac

    # Co-owned with the target app — never prunable, whatever an older manifest
    # recorded.
    if [[ -n "$protected" ]] && grep -Fxq "$rel" "$protected" 2>/dev/null; then
      continue
    fi

    stale="$dst_dir/$rel"
    [[ -f "$stale" ]] || continue

    # The lexical check above cannot see a symlinked path component. Resolve the
    # parent physically and refuse anything that lands outside the target.
    if ! inside_dir "$dst_dir" "$stale"; then
      msg_warn "REFUSING to prune outside the target (symlinked path?): $rel"
      continue
    fi

    msg_warn "PRUNE: $rel (removed from repo)"
    PRUNE_COUNT=$((PRUNE_COUNT + 1))
    [[ "$PREVIEW_ONLY" == true ]] && continue

    rm -f "$stale"
    # rmdir only removes empty directories, so this cannot delete user content.
    parent="$(dirname "$stale")"
    while [[ "$parent" != "$dst_dir" ]] && rmdir "$parent" 2>/dev/null; do
      parent="$(dirname "$parent")"
    done
  done < <(comm -23 <(sort -u "$previous") <(sort -u "$current"))
}

# commit_manifest <target-key> <current_manifest_file>
commit_manifest() {
  local target_key="$1" current="$2"
  local dest
  dest="$(manifest_path "$target_key")"

  if [[ "$PREVIEW_ONLY" == true ]]; then
    rm -f "$current"
    return 0
  fi

  mkdir -p "$MANIFEST_DIR"
  mv "$current" "$dest"
}

# ---------------------------------------------------------------------------
# Fill-missing merges
#
# Claude's settings.json, Kiro's agents/default.json, Codex's hooks.json and
# config.toml are all mutated by the app at runtime (hook registration, project
# trust, TUI state). Overwriting them wholesale loses those keys on every sync,
# so we add only the keys the destination does not already have.
#
# All three return: 0 = unchanged, 1 = updated, 2 = created.
# ---------------------------------------------------------------------------

json_fill_missing() {
  local src="$1" dst="$2"

  if [[ ! -f "$dst" ]]; then
    create_from "$src" "$dst"
    return $?
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    msg_warn "python3 not found — leaving $dst untouched"
    return 0
  fi

  local filled
  if ! filled=$(python3 - "$src" "$dst" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1]) as f:
        src = json.load(f)
    with open(sys.argv[2]) as f:
        dst = json.load(f)
except (OSError, json.JSONDecodeError) as exc:
    sys.exit("unreadable JSON: %s" % exc)

def fill(dst_node, src_node):
    """Recursively add keys src has and dst lacks. Existing values always win."""
    if not isinstance(dst_node, dict) or not isinstance(src_node, dict):
        return dst_node
    out = dict(dst_node)
    for key, value in src_node.items():
        if key in out:
            out[key] = fill(out[key], value)
        else:
            out[key] = value
    return out

print(json.dumps(fill(dst, src), indent=2))
PYEOF
  ); then
    msg_warn "Failed to merge $dst — leaving it untouched"
    return 0
  fi

  commit_merge "$dst" "$filled"
}

# commit_merge <dst> <content>
# Shared tail for the fill-missing helpers: compare byte-for-byte, then write
# atomically. Returns 0 unchanged, 1 updated. Comparison goes through a file
# rather than a hash of a command substitution — `$(...)` strips the trailing
# newline, so hashing the two sides directly never matches and every sync would
# report a spurious update.
commit_merge() {
  local dst="$1" content="$2" tmp
  tmp="$(mktemp "${dst}.vibekit.XXXXXX")" || {
    msg_warn "Could not stage a merge for $dst — leaving it untouched"
    return 0
  }
  printf '%s\n' "$content" > "$tmp"

  if cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    return 0
  fi

  if [[ "$PREVIEW_ONLY" == true ]]; then
    rm -f "$tmp"
    return 1
  fi

  if ! write_atomic "$dst" < "$tmp"; then
    rm -f "$tmp"
    msg_warn "Failed to write $dst — left unchanged"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Flat TOML only: top-level `key = value` lines and single-level `[table]`
# sections. Nested tables, arrays-of-tables and multi-line values are out of
# scope — Codex's config.toml does not use them.
toml_fill_missing() {
  local src="$1" dst="$2"

  if [[ ! -f "$dst" ]]; then
    create_from "$src" "$dst"
    return $?
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    msg_warn "python3 not found — leaving $dst untouched"
    return 0
  fi

  local filled
  if ! filled=$(python3 - "$src" "$dst" <<'PYEOF'
import re, sys

TABLE = re.compile(r"^\[[^]]*\]$")
ENTRY = re.compile(r"^\s*([^#\s][^=]*?)\s*=")
ROOT = "__root__"


def parse(lines):
    """Map section -> {key: original line}, preserving order."""
    sections, current = {ROOT: {}}, ROOT
    for line in lines:
        stripped = line.strip()
        if TABLE.match(stripped):
            current = stripped
            sections.setdefault(current, {})
            continue
        match = ENTRY.match(line)
        if match:
            sections[current][match.group(1)] = line
    return sections


with open(sys.argv[1]) as f:
    src_lines = f.read().splitlines()
with open(sys.argv[2]) as f:
    dst_lines = f.read().splitlines()

src, dst = parse(src_lines), parse(dst_lines)
out = list(dst_lines)

# Root keys go before the first table so they stay in the implicit root section.
missing_root = [line for key, line in src[ROOT].items() if key not in dst[ROOT]]
if missing_root:
    insert_at = next(
        (i for i, l in enumerate(out) if TABLE.match(l.strip())), len(out)
    )
    out[insert_at:insert_at] = missing_root

for table, entries in src.items():
    if table == ROOT:
        continue
    missing = [line for key, line in entries.items() if key not in dst.get(table, {})]
    if not missing:
        continue
    if table in dst:
        insert_at = out.index(table) + 1
        out[insert_at:insert_at] = missing
    else:
        out.extend(["", table] + missing)

print("\n".join(out))
PYEOF
  ); then
    msg_warn "Failed to merge $dst — leaving it untouched"
    return 0
  fi

  commit_merge "$dst" "$filled"
}

# sync_managed_block <src> <dst> <begin_marker> <end_marker>
#
# Replaces only the marked region of the destination, so rules the tool itself
# appended outside the block (Codex writes approved command prefixes there)
# survive the sync. If the source has no markers we refuse rather than wipe the
# destination.
sync_managed_block() {
  local src="$1" dst="$2" begin="$3" end="$4"

  # The managed region goes through a temp file rather than `awk -v`: awk
  # variables cannot carry embedded newlines.
  # An END-only or duplicated-marker source passes the extractor below but
  # produces a block that would wipe the destination's managed region.
  local src_begin src_end
  src_begin=$(grep -Fxc "$begin" "$src" || true)
  src_end=$(grep -Fxc "$end" "$src" || true)
  if [[ "$src_begin" != 1 || "$src_end" != 1 ]]; then
    msg_warn "$(basename "$src") needs exactly one managed marker pair (${src_begin} begin / ${src_end} end) — leaving $dst untouched"
    return 0
  fi
  # One of each is not enough: END before BEGIN makes the extractor emit from
  # BEGIN to EOF with no terminator, which would corrupt the destination.
  if [[ "$(grep -Fxn "$begin" "$src" | cut -d: -f1)" -gt "$(grep -Fxn "$end" "$src" | cut -d: -f1)" ]]; then
    msg_warn "$(basename "$src") has its managed markers out of order — leaving $dst untouched"
    return 0
  fi

  local managed_file
  managed_file="$(mktemp)"
  if ! awk -v b="$begin" -v e="$end" '
    $0 == b { inblock = 1 }
    inblock { print }
    $0 == e { found = 1; inblock = 0 }
    END { exit found ? 0 : 1 }
  ' "$src" > "$managed_file"; then
    rm -f "$managed_file"
    msg_warn "$(basename "$src") is missing its managed markers — leaving $dst untouched"
    return 0
  fi

  if [[ ! -f "$dst" ]]; then
    rm -f "$managed_file"
    create_from "$src" "$dst"
    return $?
  fi

  # Exactly one correctly ordered marker pair, or none at all. Two BEGIN lines,
  # or an END before its BEGIN, would make the replacement awk swallow every
  # line to EOF — deleting rules the tool itself appended.
  local n_begin n_end
  n_begin=$(grep -Fxc "$begin" "$dst" || true)
  n_end=$(grep -Fxc "$end" "$dst" || true)
  if [[ "$n_begin" -gt 1 || "$n_end" -gt 1 || "$n_begin" != "$n_end" ]]; then
    rm -f "$managed_file"
    msg_warn "$dst has malformed managed markers (${n_begin} begin / ${n_end} end) — leaving it untouched"
    return 0
  fi
  if [[ "$n_begin" -eq 1 ]] &&
     [[ "$(grep -Fxn "$begin" "$dst" | cut -d: -f1)" -gt "$(grep -Fxn "$end" "$dst" | cut -d: -f1)" ]]; then
    rm -f "$managed_file"
    msg_warn "$dst has its managed markers out of order — leaving it untouched"
    return 0
  fi

  local merged
  if [[ "$n_begin" -eq 1 ]]; then
    merged=$(awk -v b="$begin" -v e="$end" -v managed="$managed_file" '
      function emit(   line) { while ((getline line < managed) > 0) print line; close(managed) }
      $0 == b { emit(); inblock = 1; next }
      inblock && $0 == e { inblock = 0; next }
      !inblock { print }
    ' "$dst")
  else
    merged=$(printf '%s\n\n%s' "$(cat "$managed_file")" "$(cat "$dst")")
  fi
  rm -f "$managed_file"

  commit_merge "$dst" "$merged"
}

# sync_append_managed <src> <dst> <end_marker>
#
# For a file the repo owns end to end but third parties append to: Claude Code's
# ~/.claude/CLAUDE.md, where `rtk init` adds an `@RTK.md` line at the bottom. The
# repo body is authoritative and is followed by <end_marker>; every line below
# that marker belongs to whoever put it there and is carried across.
#
# The marker is written here rather than shipped in the source file, so the repo
# copy stays clean for the generators that read it verbatim.
#
# A destination laid down before the marker existed is migrated only when it is
# exactly the body we shipped plus a tail. Anything else is somebody's own file
# and is left alone — refusing is what the old overwrite should have done.
#
# Returns 0 unchanged or refused, 1 updated, 2 created.
sync_append_managed() {
  local src="$1" dst="$2" marker="$3"

  if grep -Fxq "$marker" "$src"; then
    msg_warn "$(basename "$src") already carries the managed end marker — leaving $dst untouched"
    return 0
  fi

  local created=false tail_lines=""
  if [[ ! -f "$dst" ]]; then
    created=true
  else
    local n_marker
    n_marker=$(grep -Fxc "$marker" "$dst" || true)
    if [[ "$n_marker" -gt 1 ]]; then
      msg_warn "$dst has $n_marker end markers — leaving it untouched"
      return 0
    fi
    if [[ "$n_marker" -eq 1 ]]; then
      tail_lines=$(awk -v m="$marker" 'found { print } $0 == m { found = 1 }' "$dst")
    else
      # No marker yet: the only destination we may claim is one an older sync
      # wrote, i.e. our body verbatim followed by whatever was appended to it.
      local src_lines
      src_lines=$(wc -l < "$src")
      if ! head -n "$src_lines" "$dst" | cmp -s - "$src"; then
        msg_warn "$dst has no vibekit end marker and does not match the copy we deployed — leaving it untouched"
        msg_info "Move your own additions to the bottom of the file, or delete it to take the repo copy"
        return 0
      fi
      tail_lines=$(tail -n "+$((src_lines + 1))" "$dst")
    fi
  fi

  local merged
  if [[ -n "$tail_lines" ]]; then
    merged=$(printf '%s\n%s\n%s' "$(cat "$src")" "$marker" "$tail_lines")
  else
    merged=$(printf '%s\n%s' "$(cat "$src")" "$marker")
  fi

  if [[ "$created" == true ]]; then
    [[ "$PREVIEW_ONLY" == true ]] && return 2
    mkdir -p "$(dirname "$dst")" || { msg_warn "Could not create $(dirname "$dst")"; return 0; }
    if ! printf '%s\n' "$merged" | write_atomic "$dst"; then
      msg_warn "Failed to write $dst — not created"
      return 0
    fi
    return 2
  fi

  commit_merge "$dst" "$merged"
}
