#!/bin/bash
# Guards ~/.claude/CLAUDE.md against being clobbered by the deploy.
#
# Regression: claude/CLAUDE.md was deployed by plain overwrite, so any line a
# third party appended to the deployed file was silently destroyed on the next
# sync. `rtk init` appends `@RTK.md` there; every ./install.sh run wiped it and
# RTK stopped loading. Fix: CLAUDE.md joins MERGE_MANAGED with an `append`
# strategy — the repo body is authoritative, the marker records where it ends,
# and everything below the marker is the user's and survives.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
LIB="$HERE/../lib/config-sync.sh"
INSTALL="$HERE/../lib/config-install.sh"

MARKER="<!-- END vibekit-managed CLAUDE.md — lines below are yours and survive every sync -->"

assert_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -Fq "$needle" "$file" 2>/dev/null; then _pass "$name"; else _fail "$name (missing '$needle' in $file)"; fi
}

assert_missing() {
  local file="$1" needle="$2" name="$3"
  if grep -Fq "$needle" "$file" 2>/dev/null; then _fail "$name (found '$needle' in $file)"; else _pass "$name"; fi
}

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [[ "$actual" == "$expected" ]]; then _pass "$name"; else _fail "$name (got '$actual', want '$expected')"; fi
}

_setup() {
  SANDBOX="$(make_sandbox)"
  HOME="$SANDBOX"
  MANIFEST_DIR="$SANDBOX/state"
  PREVIEW_ONLY=false
  source "$LIB"
}

# The helper does not exist before the fix; calling it would abort the suite
# with "command not found" instead of reporting a failure.
_have_helper() {
  declare -F sync_append_managed >/dev/null 2>&1
}

# --- install.sh wiring -----------------------------------------------------

# A1: CLAUDE.md is declared merge-managed, so the deploy loop stops overwriting
#     it and prune stops treating it as a plain manifest-tracked file.
test_declared_merge_managed() {
  if grep -Fq '"claude:CLAUDE.md:append"' "$INSTALL"; then
    _pass "A1: claude/CLAUDE.md is declared in MERGE_MANAGED"
  else
    _fail "A1: claude/CLAUDE.md is not in MERGE_MANAGED — it is still deployed by overwrite"
  fi
}

# A2: the append strategy is dispatched to the sync helper.
test_append_strategy_dispatched() {
  if grep -Eq 'append\)[[:space:]]*sync_append_managed' "$INSTALL"; then
    _pass "A2: the append strategy dispatches to sync_append_managed"
  else
    _fail "A2: no append) case wired to sync_append_managed in the merge dispatch"
  fi
}

# A3: the boundary marker is a named constant, like CODEX_RULES_BEGIN/END.
test_marker_constant_defined() {
  if grep -q '^CLAUDE_MD_END=' "$INSTALL"; then
    _pass "A3: CLAUDE_MD_END marker constant is defined"
  else
    _fail "A3: no CLAUDE_MD_END marker constant"
  fi
}

# --- sync_append_managed behavior ------------------------------------------

# A4: the reported bug, against the real file. A machine that ran an older sync
#     has claude/CLAUDE.md byte-for-byte at ~/.claude/CLAUDE.md with `@RTK.md`
#     appended by `rtk init`. That line must survive the next sync.
test_unmarked_dst_keeps_foreign_tail() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  if ! _have_helper; then
    _fail "A4: sync_append_managed is not defined in lib/sync.sh"
    rm -rf "$SANDBOX"; return
  fi
  local sandbox="$SANDBOX"
  local src="$HERE/../config/claude/CLAUDE.md" dst="$sandbox/CLAUDE.md"

  cp "$src" "$dst"
  printf '\n@RTK.md\n' >> "$dst"

  sync_append_managed "$src" "$dst" "$MARKER"
  assert_eq "$?" "1" "A4: returns 1 (migrated)"

  assert_contains "$dst" '@RTK.md'    "A4: the third-party @RTK.md line survives"
  assert_contains "$dst" '# CLAUDE.md' "A4: the repo body is still deployed"
  assert_eq "$(grep -Fxc "$MARKER" "$dst")" "1" "A4: exactly one boundary marker is written"
  # the marker must sit between the body and the foreign tail
  assert_eq "$(awk -v m="$MARKER" '$0 == m { seen = 1 } /^@RTK\.md$/ { print seen + 0 }' "$dst")" "1" \
    "A4: @RTK.md lands below the marker"
  rm -rf "$sandbox"
}

# A5: once the marker is in place, everything below it is untouchable — a later
#     body change must not disturb it.
test_marked_dst_keeps_tail() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  if ! _have_helper; then
    _fail "A5: sync_append_managed is not defined in lib/sync.sh"
    rm -rf "$SANDBOX"; return
  fi
  local sandbox="$SANDBOX"
  local src="$sandbox/src.md" dst="$sandbox/dst.md"

  printf '# CLAUDE.md\n\nrule_v2\n' > "$src"
  printf '# CLAUDE.md\n\nrule_v1\n%s\n\n@RTK.md\n@MY-NOTES.md\n' "$MARKER" > "$dst"

  sync_append_managed "$src" "$dst" "$MARKER"
  assert_eq "$?" "1" "A5: returns 1 (updated)"

  assert_contains "$dst" '@RTK.md'      "A5: @RTK.md below the marker survives"
  assert_contains "$dst" '@MY-NOTES.md' "A5: a second foreign line survives"
  assert_contains "$dst" 'rule_v2'      "A5: the repo body is updated"
  assert_missing  "$dst" 'rule_v1'      "A5: the stale repo body is replaced"
  rm -rf "$sandbox"
}

# A6: an unmarked destination that is not the body we shipped is somebody's own
#     file. Refuse rather than overwrite it — that is the whole point.
test_unmarked_dst_with_local_edits_is_refused() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  if ! _have_helper; then
    _fail "A6: sync_append_managed is not defined in lib/sync.sh"
    rm -rf "$SANDBOX"; return
  fi
  local sandbox="$SANDBOX"
  local src="$sandbox/src.md" dst="$sandbox/dst.md"

  printf '# CLAUDE.md\n\nrule_new\n' > "$src"
  printf '# my own notes\n\nhand written\n' > "$dst"

  sync_append_managed "$src" "$dst" "$MARKER"
  assert_eq "$?" "0" "A6: returns 0 (refused)"
  assert_contains "$dst" 'hand written' "A6: a hand-written CLAUDE.md is left untouched"
  assert_missing  "$dst" 'rule_new'     "A6: the repo body is not forced in"
  rm -rf "$sandbox"
}

# A7: an absent destination is created from source (with the marker) and
#     reports 2, so install.sh counts it as NEW.
test_absent_dst_is_created() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  if ! _have_helper; then
    _fail "A7: sync_append_managed is not defined in lib/sync.sh"
    rm -rf "$SANDBOX"; return
  fi
  local sandbox="$SANDBOX"
  local src="$sandbox/src.md" dst="$sandbox/dst.md"

  printf '# CLAUDE.md\n\nrule_new\n' > "$src"

  sync_append_managed "$src" "$dst" "$MARKER"
  assert_eq "$?" "2" "A7: returns 2 (created)"
  assert_contains "$dst" 'rule_new' "A7: body written"
  assert_eq "$(grep -Fxc "$MARKER" "$dst")" "1" "A7: marker written on creation"
  rm -rf "$sandbox"
}

# A8: a second sync with the same source is a no-op, or every run would report a
#     spurious UPDATE and rewrite the user's file.
test_repeat_sync_is_noop() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  if ! _have_helper; then
    _fail "A8: sync_append_managed is not defined in lib/sync.sh"
    rm -rf "$SANDBOX"; return
  fi
  local sandbox="$SANDBOX"
  local src="$sandbox/src.md" dst="$sandbox/dst.md"

  printf '# CLAUDE.md\n\nrule_new\n' > "$src"
  printf '# CLAUDE.md\n\nrule_new\n' > "$dst"
  printf '\n@RTK.md\n' >> "$dst"

  sync_append_managed "$src" "$dst" "$MARKER"   # migrates: adds the marker
  local before
  before="$(cat "$dst")"
  sync_append_managed "$src" "$dst" "$MARKER"
  assert_eq "$?" "0" "A8: a repeat sync reports 0 (unchanged)"
  assert_eq "$(cat "$dst")" "$before" "A8: a repeat sync does not rewrite the file"
  rm -rf "$sandbox"
}

test_declared_merge_managed
test_append_strategy_dispatched
test_marker_constant_defined
test_unmarked_dst_keeps_foreign_tail
test_marked_dst_keeps_tail
test_unmarked_dst_with_local_edits_is_refused
test_absent_dst_is_created
test_repeat_sync_is_noop
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
