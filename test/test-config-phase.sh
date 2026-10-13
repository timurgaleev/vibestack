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

# --- P9: uninstall --with-config removes ours and keeps theirs --------------
# Three ownership records bound what may be deleted: the manifest for whole
# files, the marker for the region of CLAUDE.md we wrote, and the pre/post merge
# snapshots for the keys we merged into a file someone else owns. Nothing
# outside those three is ours to touch.
test_uninstall_round_trip() {
  local sb; sb="$(new_sandbox)" || { _fail "P9: no sandbox"; return; }
  # A settings.json that existed before the pack did, with a key of its own.
  printf '{"model":"opus"}\n' > "$sb/home/.claude/settings.json"
  run_config "$sb" --target=claude >/dev/null 2>&1

  printf '\n@MY-OWN-FILE.md\n' >> "$sb/home/.claude/CLAUDE.md"
  mkdir -p "$sb/home/.claude/agents"
  echo mine > "$sb/home/.claude/agents/my-own-agent.md"

  env HOME="$sb/home" XDG_STATE_HOME="$sb/state" MANIFEST_DIR="$sb/state/vibekit" \
    bash "$REPO/uninstall" --target=claude --with-config >/dev/null 2>&1

  [[ ! -f "$sb/home/.claude/rules/git.md" ]] \
    && _pass "P9: uninstall removed the files the manifest recorded" \
    || _fail "P9: manifest-recorded files survived uninstall"

  [[ -f "$sb/home/.claude/agents/my-own-agent.md" ]] \
    && _pass "P9: a file the user added was left alone" \
    || _fail "P9: uninstall deleted a file it never installed"

  if [[ -f "$sb/home/.claude/CLAUDE.md" ]] && grep -q '@MY-OWN-FILE.md' "$sb/home/.claude/CLAUDE.md"; then
    _pass "P9: the user's lines below the marker survived uninstall"
  else
    _fail "P9: uninstall took the user's CLAUDE.md tail with it"
  fi

  # The file survives because the user owned a key in it, but the keys the pack
  # merged in — the permission grant above all — are gone again.
  if [[ -f "$sb/home/.claude/settings.json" ]] \
     && grep -q '"model"' "$sb/home/.claude/settings.json"; then
    _pass "P9: settings.json survived, with the key the user owned"
  else
    _fail "P9: uninstall deleted a file the user had keys in"
  fi

  if grep -q 'Bash(\*)' "$sb/home/.claude/settings.json" 2>/dev/null; then
    _fail "P9: the permission grant outlived the uninstall"
  else
    _pass "P9: the keys the install merged in were taken back"
  fi
}

# --- Copilot CLI ------------------------------------------------------------
# ./install's --target=copilot is registered outside this library, so these
# cases drive config_phase_run directly — the code under test either way.
# COPILOT_HOME is cleared unless a case sets it, so a developer's own value can
# never point a test at a real directory.

# run_copilot_config <sandbox> [VAR=value...] — copilot-only config phase.
run_copilot_config() {
  local sb="$1"; shift
  env -u COPILOT_HOME -u CODEX_HOME -u VIBESTACK_HOME \
      HOME="$sb/home" XDG_STATE_HOME="$sb/state" MANIFEST_DIR="$sb/state/vibekit" \
      PAYLOAD_DIR="$sb/payload" "$@" bash -c '
    set -uo pipefail
    source "$1/lib/config-install.sh"
    CFG_TARGETS="copilot"; PREVIEW_ONLY=false
    CAVEMAN=false; PONYTAIL=false; DELIBERATION=false; RTK=false
    config_phase_run
  ' _ "$REPO" 2>&1
}

copilot_payload() {
  local sb="$1"
  cp -R "$REPO/config" "$sb/payload"
}

COPILOT_END='<!-- END vibekit-managed copilot-instructions.md — lines below are yours and survive every sync -->'

tree_hash() { (cd "$1" 2>/dev/null && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256); }

# --- P10: the copilot payload lands in ~/.copilot and only there -------------
test_copilot_deploys() {
  local sb; sb="$(new_sandbox)" || { _fail "P10: no sandbox"; return; }
  copilot_payload "$sb"
  run_copilot_config "$sb" >/dev/null
  local c="$sb/home/.copilot"

  if [[ -f "$c/copilot-instructions.md" ]] && grep -qxF "$COPILOT_END" "$c/copilot-instructions.md"; then
    _pass "P10: copilot-instructions.md deployed with its own end marker"
  else
    _fail "P10: copilot-instructions.md missing or without the copilot end marker"
  fi
  [[ -f "$c/agents/code-reviewer.agent.md" && -f "$c/hooks/vibestack.json" ]] \
    && _pass "P10: agents/ and hooks/ deployed from config/copilot/" \
    || _fail "P10: agents/*.agent.md or hooks/vibestack.json not deployed"
  cmp -s "$REPO/config/copilot/hooks/vibestack.json" "$c/hooks/vibestack.json" \
    && _pass "P10: hooks/vibestack.json deployed byte-identical to the shipped file" \
    || _fail "P10: hooks/vibestack.json differs from config/copilot/hooks/vibestack.json"
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("includeCoAuthoredBy") is False else 1)' \
       "$c/settings.json" 2>/dev/null; then
    _pass "P10: settings.json carries includeCoAuthoredBy: false"
  else
    _fail "P10: settings.json missing or does not disable the co-author trailer"
  fi
  [[ ! -e "$c/config.json" ]] \
    && _pass "P10: config.json (Copilot's internal state) is never written" \
    || _fail "P10: config.json was written"
  local outside; outside=$(find "$sb/home" -type f -not -path "$c/*" | wc -l | tr -d ' ')
  [[ "$outside" -eq 0 ]] \
    && _pass "P10: nothing written outside ~/.copilot" \
    || _fail "P10: $outside file(s) written outside ~/.copilot"
  local m="$sb/state/vibekit/manifest_copilot"
  if grep -qxF 'hooks/vibestack.json' "$m" 2>/dev/null \
     && grep -qxF 'agents/code-reviewer.agent.md' "$m" \
     && ! grep -qxF 'settings.json' "$m" \
     && ! grep -qxF 'copilot-instructions.md' "$m"; then
    _pass "P10: whole files are manifest-owned, merged files are not"
  else
    _fail "P10: manifest_copilot ownership is wrong"
  fi

  local before after
  before=$(tree_hash "$c")
  run_copilot_config "$sb" >/dev/null
  after=$(tree_hash "$c")
  [[ -n "$before" && "$before" == "$after" ]] \
    && _pass "P10: a second run leaves ~/.copilot byte-identical" \
    || _fail "P10: the second run changed ~/.copilot"
}

# --- P11: COPILOT_HOME moves the whole payload -------------------------------
test_copilot_honors_copilot_home() {
  local sb; sb="$(new_sandbox)" || { _fail "P11: no sandbox"; return; }
  copilot_payload "$sb"
  run_copilot_config "$sb" COPILOT_HOME="$sb/alt" >/dev/null
  [[ -f "$sb/alt/copilot-instructions.md" && -f "$sb/alt/settings.json" && ! -e "$sb/home/.copilot" ]] \
    && _pass "P11: COPILOT_HOME receives the payload, ~/.copilot is untouched" \
    || _fail "P11: COPILOT_HOME was not honored"
}

# --- P12: the user's own copilot content survives a sync ---------------------
test_copilot_user_content_survives() {
  local sb; sb="$(new_sandbox)" || { _fail "P12: no sandbox"; return; }
  copilot_payload "$sb"
  mkdir -p "$sb/home/.copilot"
  # A user who opted into the trailer keeps that choice; their other keys stay.
  printf '{"includeCoAuthoredBy": true, "theme": "dark"}\n' > "$sb/home/.copilot/settings.json"
  run_copilot_config "$sb" >/dev/null
  printf 'my own instruction\n' >> "$sb/home/.copilot/copilot-instructions.md"
  run_copilot_config "$sb" >/dev/null

  local f="$sb/home/.copilot/copilot-instructions.md"
  if grep -q '^my own instruction$' "$f" 2>/dev/null \
     && [[ "$(grep -cxF "$COPILOT_END" "$f")" == 1 ]]; then
    _pass "P12: lines below the marker survive, one marker after two syncs"
  else
    _fail "P12: the sync lost the user's tail or duplicated the marker"
  fi
  if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("includeCoAuthoredBy") is True and d.get("theme")=="dark" else 1)' \
       "$sb/home/.copilot/settings.json" 2>/dev/null; then
    _pass "P12: the user's settings.json values win over the shipped default"
  else
    _fail "P12: the merge overwrote the user's settings.json"
  fi
}

# ./uninstall's --target=copilot belongs to the install registry; until it is
# registered the round trip cannot run, and saying so beats a silent pass.
uninstall_knows_copilot() {
  local h err
  h="$(mktemp -d)" || return 1
  err=$(env -u COPILOT_HOME HOME="$h" MANIFEST_DIR="$h/state" \
        bash "$REPO/uninstall" --target=copilot --with-config 2>&1 >/dev/null)
  rm -rf "$h"
  ! grep -q "unknown target 'copilot'" <<<"$err"
}

# --- P13: uninstall --with-config removes ours and keeps theirs --------------
test_copilot_uninstall_round_trip() {
  if ! uninstall_knows_copilot; then
    echo "  SKIP: P13: ./uninstall does not accept --target=copilot yet (install registry change pending)"
    return
  fi
  local sb; sb="$(new_sandbox)" || { _fail "P13: no sandbox"; return; }
  copilot_payload "$sb"
  mkdir -p "$sb/home/.copilot/agents"
  echo mine > "$sb/home/.copilot/agents/my-own.agent.md"
  run_copilot_config "$sb" >/dev/null
  printf 'my own instruction\n' >> "$sb/home/.copilot/copilot-instructions.md"

  env -u COPILOT_HOME HOME="$sb/home" XDG_STATE_HOME="$sb/state" MANIFEST_DIR="$sb/state/vibekit" \
    bash "$REPO/uninstall" --target=copilot --with-config >/dev/null 2>&1

  local c="$sb/home/.copilot"
  [[ ! -e "$c/agents/code-reviewer.agent.md" && ! -e "$c/hooks/vibestack.json" ]] \
    && _pass "P13: agents and hooks the manifest recorded are gone" \
    || _fail "P13: manifest-recorded copilot files survived uninstall"
  [[ -f "$c/agents/my-own.agent.md" ]] \
    && _pass "P13: an agent the user added was left alone" \
    || _fail "P13: uninstall deleted a user agent"
  if [[ -f "$c/copilot-instructions.md" ]] && grep -q '^my own instruction$' "$c/copilot-instructions.md" \
     && ! grep -q '## Authorship' "$c/copilot-instructions.md"; then
    _pass "P13: managed region stripped, the user's lines below it kept"
  else
    _fail "P13: copilot-instructions.md region not stripped, or user tail lost"
  fi
}

# --- P14: a differing file nothing claimed is the user's, not ours ----------
# Regression: a hand-written ~/.copilot/agents/<name>.agent.md that shares a
# shipped name was overwritten, recorded in the manifest, and then deleted by
# uninstall.
test_copilot_foreign_file_kept() {
  local sb; sb="$(new_sandbox)" || { _fail "P14: no sandbox"; return; }
  local c="$sb/home/.copilot" m="$sb/state/vibekit/manifest_copilot"
  local mine="$c/agents/code-reviewer.agent.md"
  mkdir -p "$c/agents"
  echo 'my own reviewer' > "$mine"
  # Identical to what ships: nothing is lost by claiming it.
  cp "$REPO/config/copilot/agents/system-designer.agent.md" "$c/agents/system-designer.agent.md"

  (unset COPILOT_HOME CODEX_HOME VIBESTACK_HOME; run_config "$sb" --target=copilot >/dev/null 2>&1)
  [[ "$(cat "$mine" 2>/dev/null)" == 'my own reviewer' ]] \
    && _pass "P14: install left the user's code-reviewer.agent.md untouched" \
    || _fail "P14: install overwrote the user's code-reviewer.agent.md"
  [[ -f "$m" ]] && ! grep -qxF 'agents/code-reviewer.agent.md' "$m" \
    && _pass "P14: manifest_copilot does not claim the user's file" \
    || _fail "P14: manifest_copilot missing or claims the user's file"
  grep -qxF 'agents/system-designer.agent.md' "$m" 2>/dev/null \
    && _pass "P14: an identical pre-existing file is claimed normally" \
    || _fail "P14: an identical pre-existing file was not claimed"

  (unset COPILOT_HOME CODEX_HOME VIBESTACK_HOME; run_config "$sb" --target=copilot >/dev/null 2>&1)
  [[ "$(cat "$mine" 2>/dev/null)" == 'my own reviewer' ]] && ! grep -qxF 'agents/code-reviewer.agent.md' "$m" \
    && _pass "P14: a second install still leaves it alone" \
    || _fail "P14: the second install overwrote or claimed the user's file"

  env -u COPILOT_HOME -u CODEX_HOME -u VIBESTACK_HOME HOME="$sb/home" XDG_STATE_HOME="$sb/state" \
    MANIFEST_DIR="$sb/state/vibekit" bash "$REPO/uninstall" --target=copilot --with-config >/dev/null 2>&1
  [[ "$(cat "$mine" 2>/dev/null)" == 'my own reviewer' ]] \
    && _pass "P14: uninstall kept the user's file" \
    || _fail "P14: uninstall deleted the user's file"
  [[ ! -e "$c/agents/system-designer.agent.md" ]] \
    && _pass "P14: uninstall removed the claimed identical file" \
    || _fail "P14: uninstall left the claimed identical file"
}

# --- P15: a file an earlier install claimed is still upgraded ---------------
test_copilot_claimed_file_updates() {
  local sb; sb="$(new_sandbox)" || { _fail "P15: no sandbox"; return; }
  copilot_payload "$sb"
  run_copilot_config "$sb" >/dev/null
  printf '\nchanged in a later release\n' >> "$sb/payload/copilot/agents/code-reviewer.agent.md"
  local out; out=$(run_copilot_config "$sb" DEBUG_TESTS=1)
  if cmp -s "$sb/payload/copilot/agents/code-reviewer.agent.md" "$sb/home/.copilot/agents/code-reviewer.agent.md" \
     && grep -qxF 'agents/code-reviewer.agent.md' "$sb/state/vibekit/manifest_copilot"; then
    _pass "P15: a claimed file whose source changed is updated and stays claimed"
  else
    _fail "P15: a claimed file was not updated on upgrade: $(grep -E 'KEEP|UPDATE' <<<"$out" | head -3)"
  fi
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
test_uninstall_round_trip
test_copilot_deploys
test_copilot_honors_copilot_home
test_copilot_user_content_survives
test_copilot_uninstall_round_trip
test_copilot_foreign_file_kept
test_copilot_claimed_file_updates

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
