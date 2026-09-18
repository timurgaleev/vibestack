#!/bin/bash
# Executable tests for the configuration phase of ./install.
#
# The other test-config-* suites read the source; these run it. Each case drives
# a real install into an isolated HOME with its own XDG state, so a failure here
# is a failure a user would have seen.
#
# RTK, Caveman, Ponytail and deliberation are left off throughout: they reach
# the network, and none of them is what these cases are about.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
REPO="$(cd "$HERE/.." && pwd)"

SANDBOXES=()
new_sandbox() {
  local d
  d="$(mktemp -d)" || return 1
  mkdir -p "$d/home/.claude" "$d/home/.codex" "$d/home/.cursor" "$d/home/.kiro"
  SANDBOXES+=("$d")
  printf '%s' "$d"
}
cleanup() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
    [[ -n "$d" && "$d" == /*/* ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

# run_config <sandbox> [extra args...] — a config-only install into that sandbox.
run_config() {
  local sb="$1"; shift
  env HOME="$sb/home" \
      XDG_STATE_HOME="$sb/state" \
      MANIFEST_DIR="$sb/state/vibekit" \
      bash "$REPO/install" --only=config --no-rtk "$@" 2>&1
}

count_files() {
  find "$1" -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}

# --- P1: a config install lands, and running it again changes nothing --------
test_install_and_idempotency() {
  local sb; sb="$(new_sandbox)" || { _fail "P1: no sandbox"; return; }
  run_config "$sb" >/dev/null 2>&1
  local n; n=$(count_files "$sb/home")
  if [[ "$n" -gt 0 ]]; then
    _pass "P1: config install deployed $n files"
  else
    _fail "P1: config install deployed nothing"
    return
  fi

  local out; out=$(run_config "$sb")
  local n2; n2=$(count_files "$sb/home")
  if [[ "$n2" == "$n" ]] && grep -q "Unchanged: *$n" <<<"$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"; then
    _pass "P1: a second run reports all $n files unchanged"
  else
    _fail "P1: second run was not idempotent ($n -> $n2)"
  fi
}

# --- P2: --target= scopes the configuration phase ---------------------------
# Regression: the phase carried its own four-target list, so --target=codex
# rewrote Claude, Cursor and Kiro configuration on the way past.
test_target_scoping() {
  local sb; sb="$(new_sandbox)" || { _fail "P2: no sandbox"; return; }
  run_config "$sb" --target=codex >/dev/null 2>&1

  local codex claude cursor
  codex=$(count_files "$sb/home/.codex")
  claude=$(count_files "$sb/home/.claude")
  cursor=$(count_files "$sb/home/.cursor")

  [[ "$codex" -gt 0 ]] \
    && _pass "P2: --target=codex wrote $codex files to ~/.codex" \
    || _fail "P2: --target=codex wrote nothing to ~/.codex"
  [[ "$claude" -eq 0 && "$cursor" -eq 0 ]] \
    && _pass "P2: --target=codex left ~/.claude and ~/.cursor alone" \
    || _fail "P2: --target=codex also wrote claude=$claude cursor=$cursor"
}

# --- P3: the user's own content survives a sync -----------------------------
test_user_content_survives() {
  local sb; sb="$(new_sandbox)" || { _fail "P3: no sandbox"; return; }
  run_config "$sb" --target=claude >/dev/null 2>&1

  printf '\n@MY-OWN-FILE.md\n' >> "$sb/home/.claude/CLAUDE.md"
  python3 - "$sb/home/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("permissions", {}).setdefault("allow", []).append("Bash(my-own-tool:*)")
d["myOwnTopLevelKey"] = True
json.dump(d, open(p, "w"), indent=2)
PY

  run_config "$sb" --target=claude >/dev/null 2>&1

  grep -q '@MY-OWN-FILE.md' "$sb/home/.claude/CLAUDE.md" \
    && _pass "P3: lines below the CLAUDE.md marker survived the sync" \
    || _fail "P3: the sync ate the user's CLAUDE.md tail"

  local markers
  markers=$(grep -c 'END vibekit-managed' "$sb/home/.claude/CLAUDE.md")
  [[ "$markers" == "1" ]] \
    && _pass "P3: exactly one managed marker after two syncs" \
    || _fail "P3: $markers markers in CLAUDE.md (expected 1)"

  if python3 - "$sb/home/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "Bash(my-own-tool:*)" in d["permissions"]["allow"], "custom allow entry lost"
assert d.get("myOwnTopLevelKey") is True, "custom top-level key lost"
PY
  then
    _pass "P3: hand-added settings.json entries survived the merge"
  else
    _fail "P3: the settings merge dropped the user's own entries"
  fi
}

# --- P4: a merge that cannot run leaves the destination alone ---------------
# Regression: a failed merge printed nothing, and that empty result was written
# over the destination — a settings.json came back as a single newline.
test_unparseable_destination_is_left_alone() {
  local sb; sb="$(new_sandbox)" || { _fail "P4: no sandbox"; return; }
  local dst="$sb/home/.claude/settings.json"
  printf '{ not valid json ]\n' > "$dst"
  local before; before=$(cat "$dst")

  local out; out=$(run_config "$sb" --target=claude)
  local after; after=$(cat "$dst")

  [[ "$before" == "$after" ]] \
    && _pass "P4: an unparseable settings.json was left byte-identical" \
    || _fail "P4: the phase overwrote a settings.json it could not parse"

  grep -q 'merge failed' <<<"$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")" \
    && _pass "P4: the refusal is reported, not silent" \
    || _fail "P4: nothing said the merge was refused"
}

# --- P5: a failure to stage the manifest must not prune ---------------------
# Regression: staging was unchecked, so a failed mktemp produced an empty
# manifest and prune read that as "the repo dropped every file" — 48 of 50
# deployed files were deleted, and the run exited 0.
test_failed_staging_does_not_prune() {
  local sb; sb="$(new_sandbox)" || { _fail "P5: no sandbox"; return; }
  run_config "$sb" --target=claude >/dev/null 2>&1
  local before; before=$(count_files "$sb/home/.claude")
  [[ "$before" -gt 0 ]] || { _fail "P5: nothing installed to test against"; return; }

  local rc=0
  env HOME="$sb/home" MANIFEST_DIR="$sb/state/vibekit" bash -c '
    set -uo pipefail
    source "'"$REPO"'/lib/config-install.sh"
    mktemp() { return 1; }          # every staging attempt fails
    CFG_TARGETS="claude"; PREVIEW_ONLY=false
    CAVEMAN=false; PONYTAIL=false; DELIBERATION=false; RTK=false
    config_phase_run
  ' >/dev/null 2>&1 || rc=$?

  local after; after=$(count_files "$sb/home/.claude")
  [[ "$after" == "$before" ]] \
    && _pass "P5: a failed staging run deleted nothing ($before files intact)" \
    || _fail "P5: staging failure pruned $((before - after)) of $before files"

  [[ "$rc" -ne 0 ]] \
    && _pass "P5: the phase reported the failure (exit $rc)" \
    || _fail "P5: the phase exited 0 after failing to stage"
}

# --- P6: contradictory phase options are refused ----------------------------
# --caveman and friends install through the config phase, so asking for one
# while excluding that phase is a contradiction, not a preference to guess at.
test_contradictory_options_refused() {
  local combos=(
    "--no-config -C"
    "--only=skills -D"
    "--only=config --no-config"
    "--only=skills --with-config"
  )
  local combo rc ok=1
  for combo in "${combos[@]}"; do
    rc=0
    # shellcheck disable=SC2086
    "$REPO/install" $combo --dry-run >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 2 ]]; then
      _fail "P6: '$combo' exited $rc (expected 2)"
      ok=0
    fi
  done
  [[ "$ok" == 1 ]] && _pass "P6: all four contradictory option pairs are refused"
}

# --- P7: --only=config validates its targets --------------------------------
# It returns before the shared resolution, so it has to do its own checking.
test_only_config_validates_targets() {
  local rc=0
  "$REPO/install" --only=config --target=definitely-not-a-target --dry-run >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] \
    && _pass "P7: --only=config rejects an unknown target" \
    || _fail "P7: --only=config accepted an unknown target (exit $rc)"
}

# --- P8: dry run writes nothing ---------------------------------------------
test_dry_run_writes_nothing() {
  local sb; sb="$(new_sandbox)" || { _fail "P8: no sandbox"; return; }
  run_config "$sb" --dry-run >/dev/null 2>&1
  local n; n=$(count_files "$sb/home")
  [[ "$n" -eq 0 ]] \
    && _pass "P8: --dry-run wrote no files" \
    || _fail "P8: --dry-run wrote $n files"
}

echo "configuration phase (executable)"
echo ""
test_install_and_idempotency
test_target_scoping
test_user_content_survives
test_unparseable_destination_is_left_alone
test_failed_staging_does_not_prune
test_contradictory_options_refused
test_only_config_validates_targets
test_dry_run_writes_nothing

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
