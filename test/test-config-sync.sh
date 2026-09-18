#!/bin/bash
# Behavior tests for lib/sync.sh (manifest prune + fill-missing merges).
# Each test runs in an isolated fake HOME so real user data is never touched.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
LIB="$HERE/../lib/config-sync.sh"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

assert_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -Fq "$needle" "$file" 2>/dev/null; then _pass "$name"; else _fail "$name (missing '$needle' in $file)"; fi
}

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [[ "$actual" == "$expected" ]]; then _pass "$name"; else _fail "$name (got '$actual', want '$expected')"; fi
}

# Load the lib against a sandboxed HOME + manifest dir. Sets SANDBOX for the
# caller — not a command substitution, so the assignments reach the caller's
# `local` copies of HOME/MANIFEST_DIR/PREVIEW_ONLY.
_setup() {
  SANDBOX="$(make_sandbox)"
  HOME="$SANDBOX"
  MANIFEST_DIR="$SANDBOX/state"
  PREVIEW_ONLY=false
  source "$LIB"
}

# --- prune -----------------------------------------------------------------

# P1: a file the repo stopped shipping is removed from the deploy target.
test_prune_removes_stale() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local dst="$sandbox/.claude/rules"
  mkdir -p "$dst" "$MANIFEST_DIR"

  touch "$dst/obsidian.md" "$dst/memex.md"
  printf 'obsidian.md\nmemex.md\n' > "$(manifest_path claude)"

  local current="$sandbox/current"
  printf 'memex.md\n' > "$current"

  prune_target claude "$dst" "$current"
  local pruned="$PRUNE_COUNT"

  assert_absent  "$dst/obsidian.md" "P1: file removed from repo is pruned"
  assert_present "$dst/memex.md"    "P1: file still in repo is kept"
  assert_eq "$pruned" "1" "P1: prune count is 1"
  rm -rf "$sandbox"
}

# P2: files this sync never deployed (user-installed) are never touched.
test_prune_spares_user_files() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local dst="$sandbox/.claude/skills"
  mkdir -p "$dst" "$MANIFEST_DIR"

  touch "$dst/vendored.md" "$dst/hand-written.md"
  printf 'vendored.md\n' > "$(manifest_path claude)"   # hand-written.md not listed

  local current="$sandbox/current"
  : > "$current"

  prune_target claude "$dst" "$current"

  assert_absent  "$dst/vendored.md"     "P2: managed file is pruned"
  assert_present "$dst/hand-written.md" "P2: unmanaged file survives"
  rm -rf "$sandbox"
}

# P3: with no previous manifest (first ever sync) nothing is deleted.
test_prune_noop_without_manifest() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local dst="$sandbox/.claude"
  mkdir -p "$dst"
  touch "$dst/pre-existing.md"

  local current="$sandbox/current"
  : > "$current"

  prune_target claude "$dst" "$current"
  local pruned="$PRUNE_COUNT"

  assert_present "$dst/pre-existing.md" "P3: first sync deletes nothing"
  assert_eq "$pruned" "0" "P3: prune count is 0"
  rm -rf "$sandbox"
}

# P4: a corrupted manifest cannot delete outside the deploy target.
test_prune_rejects_path_escape() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local dst="$sandbox/.claude"
  mkdir -p "$dst" "$MANIFEST_DIR"
  touch "$sandbox/outside.md"

  printf '../outside.md\n/etc/hosts\n' > "$(manifest_path claude)"
  local current="$sandbox/current"
  : > "$current"

  prune_target claude "$dst" "$current"

  assert_present "$sandbox/outside.md" "P4: ../ escape is refused"
  rm -rf "$sandbox"
}

# P5: preview mode reports the prune but deletes nothing.
test_prune_preview_deletes_nothing() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  PREVIEW_ONLY=true
  local dst="$sandbox/.claude"
  mkdir -p "$dst" "$MANIFEST_DIR"
  touch "$dst/stale.md"
  printf 'stale.md\n' > "$(manifest_path claude)"
  local current="$sandbox/current"
  : > "$current"

  prune_target claude "$dst" "$current"
  local pruned="$PRUNE_COUNT"

  assert_present "$dst/stale.md" "P5: preview keeps the file on disk"
  assert_eq "$pruned" "1" "P5: preview still reports the prune"
  rm -rf "$sandbox"
}

# --- json_fill_missing -----------------------------------------------------

# J1: keys the destination lacks are added; existing values are never replaced.
test_json_fill_missing() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.json" dst="$sandbox/dst.json"

  printf '{"a": 1, "nested": {"x": "repo", "y": "new"}}\n' > "$src"
  printf '{"a": 99, "nested": {"x": "local"}, "own": true}\n' > "$dst"

  json_fill_missing "$src" "$dst"
  assert_eq "$?" "1" "J1: returns 1 (updated)"

  assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["a"])' "$dst")" "99" \
    "J1: existing scalar preserved"
  assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nested"]["x"])' "$dst")" "local" \
    "J1: existing nested value preserved"
  assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nested"]["y"])' "$dst")" "new" \
    "J1: missing nested key added"
  assert_contains "$dst" '"own"' "J1: destination-only key kept"
  rm -rf "$sandbox"
}

# J2: an absent destination is created from source and reports 2.
test_json_fill_creates() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.json" dst="$sandbox/sub/dst.json"
  printf '{"a": 1}\n' > "$src"

  json_fill_missing "$src" "$dst"
  assert_eq "$?" "2" "J2: returns 2 (created)"
  assert_present "$dst" "J2: destination created"
  rm -rf "$sandbox"
}

# --- toml_fill_missing -----------------------------------------------------

# T1: missing root keys, missing keys in an existing table, and whole missing
# tables are added; existing values survive.
test_toml_fill_missing() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.toml" dst="$sandbox/dst.toml"

  cat > "$src" <<'EOF'
approval_policy = "on-request"
web_search = "live"

[features]
hooks = true

[permissions.git-write.network]
enabled = true
EOF

  cat > "$dst" <<'EOF'
approval_policy = "never"

[features]
tui = "fullscreen"
EOF

  toml_fill_missing "$src" "$dst"
  assert_eq "$?" "1" "T1: returns 1 (updated)"

  assert_contains "$dst" 'approval_policy = "never"'  "T1: existing root key preserved"
  assert_contains "$dst" 'web_search = "live"'        "T1: missing root key added"
  assert_contains "$dst" 'tui = "fullscreen"'         "T1: existing table key preserved"
  assert_contains "$dst" 'hooks = true'               "T1: missing table key added"
  assert_contains "$dst" '[permissions.git-write.network]' "T1: missing table added"
  rm -rf "$sandbox"
}

# T2: identical content is a no-op (return 0, file untouched).
test_toml_fill_noop() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.toml" dst="$sandbox/dst.toml"
  printf 'a = 1\n' > "$src"
  printf 'a = 1\n' > "$dst"

  toml_fill_missing "$src" "$dst"
  assert_eq "$?" "0" "T2: returns 0 (unchanged)"
  rm -rf "$sandbox"
}

# --- sync_managed_block ----------------------------------------------------

BEGIN_MARKER="# BEGIN vibekit managed codex rules"
END_MARKER="# END vibekit managed codex rules"

# M1: only the marked region is replaced; rules outside it survive.
test_managed_block_preserves_outside() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.rules" dst="$sandbox/dst.rules"

  printf '%s\nrule_new()\n%s\n' "$BEGIN_MARKER" "$END_MARKER" > "$src"
  printf '%s\nrule_old()\n%s\nlocal_rule()\n' "$BEGIN_MARKER" "$END_MARKER" > "$dst"

  sync_managed_block "$src" "$dst" "$BEGIN_MARKER" "$END_MARKER"
  assert_eq "$?" "1" "M1: returns 1 (updated)"

  assert_contains "$dst" 'rule_new()'   "M1: managed block updated"
  assert_contains "$dst" 'local_rule()' "M1: rule outside the block survives"
  if grep -Fq 'rule_old()' "$dst"; then _fail "M1: stale managed rule removed"; else _pass "M1: stale managed rule removed"; fi
  rm -rf "$sandbox"
}

# M2: a source without markers must not wipe the destination.
test_managed_block_refuses_unmarked_source() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.rules" dst="$sandbox/dst.rules"

  printf 'no markers here\n' > "$src"
  printf 'local_rule()\n' > "$dst"

  sync_managed_block "$src" "$dst" "$BEGIN_MARKER" "$END_MARKER"
  assert_eq "$?" "0" "M2: returns 0 (refused)"
  assert_contains "$dst" 'local_rule()' "M2: destination left untouched"
  rm -rf "$sandbox"
}

# M3: an unmanaged destination gets the block prepended, keeping its content.
test_managed_block_prepends_to_unmanaged() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.rules" dst="$sandbox/dst.rules"

  printf '%s\nrule_new()\n%s\n' "$BEGIN_MARKER" "$END_MARKER" > "$src"
  printf 'pre_existing()\n' > "$dst"

  sync_managed_block "$src" "$dst" "$BEGIN_MARKER" "$END_MARKER"

  assert_contains "$dst" 'rule_new()'     "M3: managed block added"
  assert_contains "$dst" 'pre_existing()' "M3: pre-existing rule kept"
  rm -rf "$sandbox"
}

# --- regressions from the Codex review -------------------------------------

# R1: a symlinked path component must not carry a delete outside the target.
# The lexical ../ check does not see this — only physical resolution does.
test_prune_refuses_symlink_escape() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local dst="$sandbox/.claude"
  mkdir -p "$dst" "$MANIFEST_DIR" "$sandbox/outside"
  touch "$sandbox/outside/victim.md"
  ln -s "$sandbox/outside" "$dst/rules"

  printf 'rules/victim.md\n' > "$(manifest_path claude)"
  local current="$sandbox/current"
  : > "$current"

  prune_target claude "$dst" "$current"

  assert_present "$sandbox/outside/victim.md" "R1: symlinked component cannot escape the target"
  assert_eq "$PRUNE_COUNT" "0" "R1: nothing counted as pruned"
  rm -rf "$sandbox"
}

# R2: an unchanged JSON destination must report 0, not rewrite itself every sync.
test_json_unchanged_is_noop() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.json" dst="$sandbox/dst.json"
  printf '{"a": 1}\n' > "$src"
  printf '{\n  "a": 1\n}\n' > "$dst"

  json_fill_missing "$src" "$dst"
  assert_eq "$?" "0" "R2: identical JSON reports unchanged"
  rm -rf "$sandbox"
}

# R3: a duplicated BEGIN marker must not let awk swallow the file to EOF.
test_managed_block_refuses_duplicate_markers() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.rules" dst="$sandbox/dst.rules"

  printf '%s\nrule_new()\n%s\n' "$BEGIN_MARKER" "$END_MARKER" > "$src"
  printf '%s\n%s\nrule_old()\n%s\nlocal_rule()\n' \
    "$BEGIN_MARKER" "$BEGIN_MARKER" "$END_MARKER" > "$dst"

  sync_managed_block "$src" "$dst" "$BEGIN_MARKER" "$END_MARKER"
  assert_eq "$?" "0" "R3: malformed markers refused"
  assert_contains "$dst" 'local_rule()' "R3: user rule after the markers survives"
  rm -rf "$sandbox"
}

# R4: markers in the wrong order are refused rather than acted on.
test_managed_block_refuses_reversed_markers() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.rules" dst="$sandbox/dst.rules"

  printf '%s\nrule_new()\n%s\n' "$BEGIN_MARKER" "$END_MARKER" > "$src"
  printf '%s\nstranded()\n%s\nlocal_rule()\n' "$END_MARKER" "$BEGIN_MARKER" > "$dst"

  sync_managed_block "$src" "$dst" "$BEGIN_MARKER" "$END_MARKER"
  assert_eq "$?" "0" "R4: reversed markers refused"
  assert_contains "$dst" 'local_rule()' "R4: destination left untouched"
  rm -rf "$sandbox"
}

# R5: the real write_atomic must leave the destination untouched when it cannot
# complete — no stub, so this exercises the actual atomicity guarantee. The
# destination directory is made read-only so the temp file cannot be created.
# R9: a source whose markers are in the wrong order must be refused. Counting
# one of each is not enough — the extractor would emit BEGIN through EOF.
test_managed_block_refuses_reversed_source() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.rules" dst="$sandbox/dst.rules"

  printf '%s\nstranded()\n%s\ntail()\n' "$END_MARKER" "$BEGIN_MARKER" > "$src"
  printf '%s\nrule_managed()\n%s\nlocal_rule()\n' "$BEGIN_MARKER" "$END_MARKER" > "$dst"

  sync_managed_block "$src" "$dst" "$BEGIN_MARKER" "$END_MARKER"
  assert_eq "$?" "0" "R9: reversed source markers refused"
  assert_contains "$dst" 'rule_managed()' "R9: managed region not wiped"
  assert_contains "$dst" 'local_rule()'   "R9: local rule intact"
  rm -rf "$sandbox"
}

test_managed_block_refuses_reversed_source
test_write_atomic_leaves_destination_intact() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  local sandbox="$SANDBOX"
  local dir="$sandbox/locked"
  mkdir -p "$dir"
  local dst="$dir/config.json"
  printf '{"keep": true}\n' > "$dst"
  chmod 500 "$dir"

  printf 'REPLACEMENT' | write_atomic "$dst"
  local rc=$?

  chmod 700 "$dir"
  assert_eq "$rc" "1" "R5: write_atomic reports failure"
  assert_contains "$dst" '"keep"' "R5: original content intact"
  if grep -q 'REPLACEMENT' "$dst"; then _fail "R5: destination not partially written"; else _pass "R5: destination not partially written"; fi
  # No temp files left behind.
  if ls "$dir"/*.vibekit.* >/dev/null 2>&1; then _fail "R5: no stray temp file"; else _pass "R5: no stray temp file"; fi
  rm -rf "$sandbox"
}

# R6: commit_merge propagates a write failure as "unchanged", never "updated".
test_merge_write_failure_reports_unchanged() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  local sandbox="$SANDBOX"
  local dst="$sandbox/dst.json"
  printf '{"keep": true}\n' > "$dst"

  write_atomic() { return 1; }
  commit_merge "$dst" '{"keep": true, "added": 1}'
  local rc=$?
  unset -f write_atomic

  assert_eq "$rc" "0" "R6: failed write reports unchanged, not updated"
  assert_contains "$dst" '"keep"' "R6: destination not truncated"
  rm -rf "$sandbox"
}

# R7: a merge-managed file named by an OLD manifest must survive, even though
# this sync no longer records it. Excluding it from the current manifest alone
# would let prune read it as "dropped from the repo".
test_prune_spares_protected_paths() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX PRUNE_COUNT
  _setup
  local sandbox="$SANDBOX"
  local dst="$sandbox/.codex"
  mkdir -p "$dst" "$MANIFEST_DIR"
  printf 'trust = "local"\n' > "$dst/config.toml"
  touch "$dst/dropped.md"

  # An older manifest from before config.toml became merge-managed.
  printf 'config.toml\ndropped.md\n' > "$(manifest_path codex)"
  local current="$sandbox/current" protected="$sandbox/protected"
  : > "$current"
  printf 'config.toml\n' > "$protected"

  prune_target codex "$dst" "$current" "$protected"

  assert_present "$dst/config.toml" "R7: protected file survives an old manifest entry"
  assert_absent  "$dst/dropped.md"  "R7: an ordinary dropped file is still pruned"
  assert_eq "$PRUNE_COUNT" "1" "R7: only the unprotected file counted"
  rm -rf "$sandbox"
}

# R8: a source lacking a well-formed marker pair must not wipe the managed
# region of a valid destination.
test_managed_block_refuses_malformed_source() {
  local HOME MANIFEST_DIR PREVIEW_ONLY SANDBOX
  _setup
  local sandbox="$SANDBOX"
  local src="$sandbox/src.rules" dst="$sandbox/dst.rules"

  # END only — the extractor would return an empty block.
  printf '%s\n' "$END_MARKER" > "$src"
  printf '%s\nrule_managed()\n%s\nlocal_rule()\n' "$BEGIN_MARKER" "$END_MARKER" > "$dst"

  sync_managed_block "$src" "$dst" "$BEGIN_MARKER" "$END_MARKER"
  assert_eq "$?" "0" "R8: malformed source refused"
  assert_contains "$dst" 'rule_managed()' "R8: managed region not wiped"
  assert_contains "$dst" 'local_rule()'   "R8: local rule intact"
  rm -rf "$sandbox"
}

test_prune_removes_stale
test_prune_spares_user_files
test_prune_refuses_symlink_escape
test_json_unchanged_is_noop
test_managed_block_refuses_duplicate_markers
test_managed_block_refuses_reversed_markers
test_write_atomic_leaves_destination_intact
test_merge_write_failure_reports_unchanged
test_prune_spares_protected_paths
test_managed_block_refuses_malformed_source
test_prune_noop_without_manifest
test_prune_rejects_path_escape
test_prune_preview_deletes_nothing
test_json_fill_missing
test_json_fill_creates
test_toml_fill_missing
test_toml_fill_noop
test_managed_block_preserves_outside
test_managed_block_refuses_unmarked_source
test_managed_block_prepends_to_unmanaged


# --- TOML: refuse rather than write what cannot be checked ---------------------
# The merge is line-based, so the only thing standing between it and a file the
# tool cannot read is a parser. tomllib arrives in python 3.11, and stock macOS
# Command Line Tools ships 3.9 — the released version rewrote those machines'
# config.toml unvalidated, and four shapes came out invalid.
test_toml_refuses_without_a_validator() {
  local d shim rc before after
  d=$(mktemp -d); shim=$(mktemp -d)
  # A python3 whose tomllib import fails, standing in for 3.8-3.10.
  # The interpreter is resolved BEFORE the shim goes on PATH — a shim named
  # python3 that calls "python3" re-enters itself, and the test then passes
  # because the shim crashed rather than because tomllib was absent.
  local real_py; real_py=$(command -v python3)
  cat > "$shim/python3" <<SHIM
#!/bin/bash
exec "$real_py" -c '
import sys, builtins
_real = builtins.__import__
def _block(name, *a, **k):
    if name == "tomllib":
        raise ImportError("simulated: no tomllib")
    return _real(name, *a, **k)
builtins.__import__ = _block
_src = sys.stdin.read()
sys.argv = sys.argv[1:]
exec(compile(_src, "<stdin>", "exec"))
' "\$@"
SHIM
  chmod +x "$shim/python3"

  printf 'features.hooks = false\n' > "$d/config.toml"
  before=$(cat "$d/config.toml")
  PATH="$shim:$PATH" toml_fill_missing "$REPO_ROOT/config/codex/config.toml" "$d/config.toml" >/dev/null 2>&1
  rc=$?
  after=$(cat "$d/config.toml")

  [[ "$rc" == 3 ]] \
    && _pass "T-refuse: no tomllib returns 3 (refused), not 0 (unchanged)" \
    || _fail "T-refuse: no tomllib returned $rc (expected 3)"
  [[ "$before" == "$after" ]] \
    && _pass "T-refuse: the destination was left byte-identical" \
    || _fail "T-refuse: the destination was rewritten without a validator"
  rm -rf "$d" "$shim"
}

# A multi-line string can contain a line that reads as a table header. Inserting
# into it yields VALID TOML with the user's value silently rewritten, so
# validating the result cannot catch this one — it has to be refused up front.
test_toml_refuses_multiline_string() {
  local d rc before after
  d=$(mktemp -d)
  printf 'note = %s\n[features]\nhooks = false\n%s\n' '"""' '"""' > "$d/config.toml"
  before=$(cat "$d/config.toml")
  toml_fill_missing "$REPO_ROOT/config/codex/config.toml" "$d/config.toml" >/dev/null 2>&1
  rc=$?
  after=$(cat "$d/config.toml")
  [[ "$rc" == 3 && "$before" == "$after" ]] \
    && _pass "T-multiline: a multi-line string is refused, not written into" \
    || _fail "T-multiline: rc=$rc, destination changed=$([[ "$before" == "$after" ]] && echo no || echo YES)"
  rm -rf "$d"
}

# A quoted table key containing "]" defeats the header pattern, so the repo's
# root keys would land under that table instead of at root.
test_toml_refuses_quoted_table_key() {
  local d rc before after
  d=$(mktemp -d)
  printf '["we]ird"]\nk = 1\n' > "$d/config.toml"
  before=$(cat "$d/config.toml")
  toml_fill_missing "$REPO_ROOT/config/codex/config.toml" "$d/config.toml" >/dev/null 2>&1
  rc=$?
  after=$(cat "$d/config.toml")
  [[ "$rc" == 3 && "$before" == "$after" ]] \
    && _pass "T-quotedkey: a quoted table key is refused" \
    || _fail "T-quotedkey: rc=$rc, destination changed=$([[ "$before" == "$after" ]] && echo no || echo YES)"
  rm -rf "$d"
}

# The ordinary case still has to merge, or the guards above have simply turned
# the feature off.
test_toml_still_merges_a_plain_destination() {
  local d rc
  d=$(mktemp -d)
  printf '[features]\nhooks = false\n' > "$d/config.toml"
  toml_fill_missing "$REPO_ROOT/config/codex/config.toml" "$d/config.toml" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" == 1 ]] && grep -q 'hooks = false' "$d/config.toml" \
     && python3 -c "import tomllib,sys; tomllib.load(open('$d/config.toml','rb'))" 2>/dev/null; then
    _pass "T-plain: a plain destination still merges, keeps its value, and parses"
  else
    _fail "T-plain: rc=$rc — the ordinary merge path regressed"
  fi
  rm -rf "$d"
}

test_toml_refuses_without_a_validator
test_toml_refuses_multiline_string
test_toml_refuses_quoted_table_key
test_toml_still_merges_a_plain_destination

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
