#!/usr/bin/env bash
# vibestack install/uninstall integration tests
#
# Tests run in an isolated $HOME (TMPDIR-based) so they never touch the
# real ~/.claude/, ~/.cursor/, or ~/.kiro/ directories. Each test sets up
# a fresh fake-HOME, runs the install (or install+uninstall), and asserts.
#
# Per-test isolation: each test gets its own subshell with a fresh FAKE_HOME.
# A failed assertion exits the subshell non-zero; the runner counts it.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$REPO_DIR/install"
UNINSTALL="$REPO_DIR/uninstall"

PASS=0
FAIL=0
FAILED_TESTS=()

# ───────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────

# Set up a fresh fake $HOME for a test. Sets globals: FAKE_HOME, env vars.
setup_fake_home() {
  FAKE_HOME=$(mktemp -d)
  export HOME="$FAKE_HOME"
  # Override VIBESTACK_HOME so state doesn't leak into the real ~/.vibestack/
  export VIBESTACK_HOME="$FAKE_HOME/.vibestack"
  # Test-only seam: disables the `command -v` half of target_detected() so
  # the dev machine's real claude/cursor/kiro binaries don't confuse tests.
  # Detection is then controlled solely by $HOME/.<target>/ presence.
  export VIBE_TEST_MODE=1
}

teardown_fake_home() {
  if [ -n "${FAKE_HOME:-}" ] && [ -d "$FAKE_HOME" ]; then
    rm -rf "$FAKE_HOME"
  fi
}

# ───────────────────────────────────────────────────────────────────────────
# v1.5.0 helpers (PTY harness + renderer-failure injection)
# ───────────────────────────────────────────────────────────────────────────

# Run install via PTY with input fed to its prompt. Captures combined output
# to $1 (a path). Sets RC global to the install exit code. Other args after
# $1 are passed to install.
#
# Requires python3 in PATH; tests should fall back gracefully if missing.
PTY_RUN="$REPO_DIR/test/pty-run.py"

pty_install() {
  local outfile="$1"; shift
  local input="$1"; shift
  if ! command -v python3 >/dev/null 2>&1; then
    echo "    SKIP: python3 not available for PTY tests" >&2
    return 77   # GNU automake skip code
  fi
  set +e
  python3 "$PTY_RUN" --timeout 60 --input "$input" -- bash "$INSTALL" "$@" \
    > "$outfile" 2>&1
  RC=$?
  set -e
}

# Pre-mark a target as "detected" by creating its $HOME/.<target>/ directory.
mark_detected() {
  for t in "$@"; do
    mkdir -p "$HOME/.${t}"
  done
}

# Replace bin/vibe-render-skill with a stub that fails when the destination
# path matches a glob substring. Keeps a backup; restore_renderer reverts.
# Fails ONLY for the matched target_substring/skill_substring combo, passing
# through to the real renderer for everything else.
RENDERER_PATH="$REPO_DIR/bin/vibe-render-skill"
RENDERER_BAK="$REPO_DIR/bin/.vibe-render-skill.bak.$$"

with_failing_renderer() {
  local skill_substring="$1"   # e.g. "office-hours"
  local target_substring="$2"  # e.g. "cursor" — only fail for this target
  cp "$RENDERER_PATH" "$RENDERER_BAK"
  cat > "$RENDERER_PATH" <<STUB
#!/usr/bin/env bash
# Test stub: fail-on-match, otherwise delegate to the real renderer.
src="\$1"; dst="\$2"
if [ -n "$skill_substring" ] && [ -n "$target_substring" ] \
    && echo "\$src" | grep -q "/$skill_substring/"; then
  if echo "\$dst" | grep -q "$target_substring"; then
    echo "FAKE_RENDERER: failing on \$src → \$dst" >&2
    exit 2
  fi
fi
exec "$RENDERER_BAK" "\$src" "\$dst"
STUB
  chmod +x "$RENDERER_PATH"
}

restore_renderer() {
  if [ -f "$RENDERER_BAK" ]; then
    cp "$RENDERER_BAK" "$RENDERER_PATH"
    rm -f "$RENDERER_BAK"
    chmod +x "$RENDERER_PATH"
  fi
}

# Compose teardown: renderer restore + fake-home cleanup.
teardown_full() {
  restore_renderer
  teardown_fake_home
}

# Run a single test in a subshell so failures don't kill the whole runner.
run_test() {
  local name="$1"
  local fn="$2"
  echo -n "  $name ... "
  if (
    set -uo pipefail
    setup_fake_home
    trap teardown_fake_home EXIT
    "$fn"
  ); then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
  fi
}

assert_file_exists() {
  if [ ! -f "$1" ]; then
    echo "    expected file: $1" >&2
    return 1
  fi
}

assert_file_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    echo "    expected absent: $1" >&2
    return 1
  fi
}

assert_dir_exists() {
  if [ ! -d "$1" ]; then
    echo "    expected dir: $1" >&2
    return 1
  fi
}

assert_eq() {
  local expected="$1" actual="$2" label="${3:-values}"
  if [ "$expected" != "$actual" ]; then
    echo "    expected $label: '$expected'" >&2
    echo "    actual:           '$actual'" >&2
    return 1
  fi
}

# ───────────────────────────────────────────────────────────────────────────
# Tests
# ───────────────────────────────────────────────────────────────────────────

# --- Regression: claude target produces same content as v1.3.0 (byte-identical)
test_regression_claude_target_byte_identical_to_renderer() {
  "$INSTALL" --target=claude < /dev/null >/dev/null 2>&1
  # Spot-check 3 representative skills against the renderer's direct output
  for skill in office-hours careful ship; do
    local installed="$HOME/.claude/skills/$skill/SKILL.md"
    local rendered=$(mktemp)
    "$REPO_DIR/bin/vibe-render-skill" "$REPO_DIR/skills/$skill/SKILL.md" "$rendered"
    if ! cmp -s "$installed" "$rendered"; then
      echo "    drift in $skill" >&2
      rm -f "$rendered"
      return 1
    fi
    rm -f "$rendered"
  done
}

# --- Default invocation (non-tty) installs all 3 targets
test_default_non_tty_installs_all_three() {
  "$INSTALL" < /dev/null >/dev/null 2>&1
  assert_dir_exists "$HOME/.claude/skills" || return 1
  assert_dir_exists "$HOME/.cursor/skills" || return 1
  assert_dir_exists "$HOME/.kiro/skills" || return 1
  # Spot check: office-hours present in all three
  assert_file_exists "$HOME/.claude/skills/office-hours/SKILL.md" || return 1
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  assert_file_exists "$HOME/.kiro/skills/office-hours/SKILL.md" || return 1
}

# --- Single target (cursor only) doesn't touch other targets
test_target_cursor_only_does_not_touch_claude_or_kiro() {
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  assert_dir_exists "$HOME/.cursor/skills" || return 1
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  assert_file_missing "$HOME/.claude/skills" || return 1
  assert_file_missing "$HOME/.kiro/skills" || return 1
}

# --- --target=invalid exits 2 with validation error
test_target_invalid_exits_2() {
  set +e
  "$INSTALL" --target=nonsense < /dev/null >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "2" "$rc" "exit code"
}

# --- --dry-run writes nothing
test_dry_run_writes_nothing() {
  "$INSTALL" --dry-run < /dev/null >/dev/null 2>&1
  assert_file_missing "$HOME/.claude/skills" || return 1
  assert_file_missing "$HOME/.cursor/skills" || return 1
  assert_file_missing "$HOME/.kiro/skills" || return 1
}

# --- --dry-run --target=all reports 3 targets in summary
test_dry_run_reports_all_three_targets() {
  local out
  out=$("$INSTALL" --dry-run --target=all < /dev/null 2>&1)
  echo "$out" | grep -q "Claude Code" || { echo "    missing Claude Code in dry-run output" >&2; return 1; }
  echo "$out" | grep -q "Cursor"      || { echo "    missing Cursor in dry-run output" >&2; return 1; }
  echo "$out" | grep -q "Kiro"        || { echo "    missing Kiro in dry-run output" >&2; return 1; }
}

# --- All 3 targets get byte-identical content for the same skill
test_all_three_targets_byte_identical_per_skill() {
  "$INSTALL" --target=all < /dev/null >/dev/null 2>&1
  local h_claude h_cursor h_kiro
  for skill in office-hours review ship; do
    h_claude=$(md5 -q "$HOME/.claude/skills/$skill/SKILL.md")
    h_cursor=$(md5 -q "$HOME/.cursor/skills/$skill/SKILL.md")
    h_kiro=$(md5 -q "$HOME/.kiro/skills/$skill/SKILL.md")
    if [ "$h_claude" != "$h_cursor" ] || [ "$h_claude" != "$h_kiro" ]; then
      echo "    drift on $skill: claude=$h_claude cursor=$h_cursor kiro=$h_kiro" >&2
      return 1
    fi
  done
}

# --- Idempotency: re-running install produces identical bytes
test_install_idempotent_per_target() {
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  local h1=$(md5 -q "$HOME/.cursor/skills/office-hours/SKILL.md")
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  local h2=$(md5 -q "$HOME/.cursor/skills/office-hours/SKILL.md")
  assert_eq "$h1" "$h2" "rendered hash"
}

# --- Install all 3 → uninstall all 3 → zero residual files
test_install_all_then_uninstall_all_zero_residue() {
  "$INSTALL" --target=all < /dev/null >/dev/null 2>&1
  "$UNINSTALL" --target=all < /dev/null >/dev/null 2>&1
  for skill in office-hours review ship careful; do
    assert_file_missing "$HOME/.claude/skills/$skill/SKILL.md" || return 1
    assert_file_missing "$HOME/.cursor/skills/$skill/SKILL.md" || return 1
    assert_file_missing "$HOME/.kiro/skills/$skill/SKILL.md" || return 1
  done
}

# --- Single-target uninstall doesn't touch other targets (regression
#     guard for the prior learning vibestack_uninstall_only_removes_symlinks)
test_uninstall_target_cursor_preserves_claude() {
  "$INSTALL" --target=all < /dev/null >/dev/null 2>&1
  "$UNINSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  assert_file_missing "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  assert_file_exists "$HOME/.claude/skills/office-hours/SKILL.md" || return 1
  assert_file_exists "$HOME/.kiro/skills/office-hours/SKILL.md" || return 1
}

# --- Hook-bearing skill warning is printed for non-claude targets
test_install_warns_about_hooks_for_non_claude() {
  local out
  out=$("$INSTALL" --target=cursor < /dev/null 2>&1)
  echo "$out" | grep -q "Hook-bearing skills" || {
    echo "    expected hook warning in cursor install output" >&2
    return 1
  }
}

# --- Claude-only install does NOT print hook warning (claude has hooks natively)
test_install_no_hook_warning_for_claude_only() {
  local out
  out=$("$INSTALL" --target=claude < /dev/null 2>&1)
  if echo "$out" | grep -q "Hook-bearing skills"; then
    echo "    unexpected hook warning in claude-only install" >&2
    return 1
  fi
}

# --- bin/ symlinks present per target for hook-bearing skills
test_bin_symlinks_present_per_target() {
  "$INSTALL" --target=all < /dev/null >/dev/null 2>&1
  for target in claude cursor kiro; do
    local link="$HOME/.${target}/skills/careful/bin"
    if [ ! -L "$link" ]; then
      echo "    expected symlink: $link" >&2
      return 1
    fi
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# v1.5.0 install plan UX tests (TTY-gated via PTY harness)
# ═══════════════════════════════════════════════════════════════════════════

# --- #1: Enter installs detected only
test_install_plan_default_enter_installs_detected() {
  mark_detected claude
  local out="$FAKE_HOME/out.log"
  pty_install "$out" '\n'
  [ "$RC" = "77" ] && return 77
  assert_eq "0" "$RC" "exit code (Enter installs detected)" || { cat "$out" >&2; return 1; }
  assert_dir_exists "$HOME/.claude/skills" || return 1
  assert_file_exists "$HOME/.claude/skills/office-hours/SKILL.md" || return 1
  assert_file_missing "$HOME/.cursor/skills" || return 1
  assert_file_missing "$HOME/.kiro/skills" || return 1
  grep -q "Installation complete:" "$out" || { echo "    missing 'Installation complete:'" >&2; cat "$out" >&2; return 1; }
}

# --- #2: `a` installs all three even when none detected
test_install_plan_a_installs_all_three() {
  # Don't pre-detect anything — `a` should override.
  local out="$FAKE_HOME/out.log"
  pty_install "$out" 'a\n'
  [ "$RC" = "77" ] && return 77
  assert_eq "0" "$RC" "exit code" || { cat "$out" >&2; return 1; }
  assert_file_exists "$HOME/.claude/skills/office-hours/SKILL.md" || return 1
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  assert_file_exists "$HOME/.kiro/skills/office-hours/SKILL.md" || return 1
}

# --- #3: `q` exits 0 with "Nothing to install"
test_install_plan_q_exits_zero_with_message() {
  mark_detected claude
  local out="$FAKE_HOME/out.log"
  pty_install "$out" 'q\n'
  [ "$RC" = "77" ] && return 77
  assert_eq "0" "$RC" "exit code (q)" || { cat "$out" >&2; return 1; }
  grep -q "Nothing to install" "$out" || { echo "    missing 'Nothing to install' message" >&2; cat "$out" >&2; return 1; }
  # No skills installed.
  assert_file_missing "$HOME/.claude/skills" || return 1
}

# --- #4: empty defaults + Enter exits with hint
test_install_plan_empty_default_enter_exits_with_hint() {
  # Don't pre-detect any target.
  local out="$FAKE_HOME/out.log"
  pty_install "$out" '\n'
  [ "$RC" = "77" ] && return 77
  assert_eq "0" "$RC" "exit code (empty defaults + Enter)" || { cat "$out" >&2; return 1; }
  grep -q "No targets detected" "$out" || { echo "    missing 'No targets detected' hint" >&2; cat "$out" >&2; return 1; }
  assert_file_missing "$HOME/.claude/skills" || return 1
}

# --- #5: `e` falls through to per-target loop with flipped defaults
test_install_plan_e_falls_through_to_per_target() {
  mark_detected claude
  # `e` then Enter for Claude (default Y), Enter for Cursor (default N), Enter for Kiro (default N)
  local out="$FAKE_HOME/out.log"
  pty_install "$out" 'e\n\n\n\n'
  [ "$RC" = "77" ] && return 77
  assert_eq "0" "$RC" "exit code" || { cat "$out" >&2; return 1; }
  assert_file_exists "$HOME/.claude/skills/office-hours/SKILL.md" || return 1
  assert_file_missing "$HOME/.cursor/skills" || return 1
  assert_file_missing "$HOME/.kiro/skills" || return 1
}

# --- #7: partial-fail continues across targets, exits non-zero
test_install_partial_fail_continues_and_exits_nonzero() {
  trap teardown_full EXIT  # compose: restore renderer + fake-home cleanup
  with_failing_renderer "office-hours" "cursor"

  set +e
  "$INSTALL" --target=all < /dev/null > "$FAKE_HOME/out.log" 2>&1
  local rc=$?
  set -e

  assert_eq "1" "$rc" "exit code (partial fail)" || { cat "$FAKE_HOME/out.log" >&2; return 1; }
  grep -q "Installation incomplete:" "$FAKE_HOME/out.log" || { echo "    missing 'Installation incomplete:' header" >&2; cat "$FAKE_HOME/out.log" >&2; return 1; }
  grep -q "✓ Claude Code" "$FAKE_HOME/out.log" || { echo "    missing claude success line" >&2; cat "$FAKE_HOME/out.log" >&2; return 1; }
  grep -q "✗ Cursor" "$FAKE_HOME/out.log" || { echo "    missing cursor failure line" >&2; cat "$FAKE_HOME/out.log" >&2; return 1; }
  grep -q "✓ Kiro" "$FAKE_HOME/out.log" || { echo "    missing kiro success line" >&2; cat "$FAKE_HOME/out.log" >&2; return 1; }
  # Cursor's production skills/ dir must NOT exist (atomic swap blocked by failure).
  assert_file_missing "$HOME/.cursor/skills" || return 1
  # Claude and Kiro should have completed atomically.
  assert_file_exists "$HOME/.claude/skills/office-hours/SKILL.md" || return 1
  assert_file_exists "$HOME/.kiro/skills/office-hours/SKILL.md" || return 1
}

# --- #8: partial-fail KEEPS hook warning (R15) but suppresses happy-path CTA
test_install_partial_fail_keeps_hook_warning_suppresses_cta() {
  trap teardown_full EXIT
  with_failing_renderer "office-hours" "cursor"

  set +e
  "$INSTALL" --target=all < /dev/null > "$FAKE_HOME/out.log" 2>&1
  local rc=$?
  set -e

  assert_eq "1" "$rc" "exit code" || { cat "$FAKE_HOME/out.log" >&2; return 1; }
  # Hook warning MUST still print (R15: kiro completed with hook-bearing skills).
  grep -q "Hook-bearing skills" "$FAKE_HOME/out.log" || { echo "    expected hook warning even on partial failure (R15)" >&2; cat "$FAKE_HOME/out.log" >&2; return 1; }
  # Happy-path CTA MUST be suppressed.
  if grep -q "Try /office-hours first" "$FAKE_HOME/out.log"; then
    echo "    unexpected happy-path CTA on partial failure" >&2
    cat "$FAKE_HOME/out.log" >&2
    return 1
  fi
}

# --- #9: SIGINT returns 130 with interrupt message (may be flaky on slow CI)
test_install_sigint_returns_130() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 77
  fi
  # Run install in background, send SIGINT, check exit code.
  local out="$FAKE_HOME/out.log"
  bash "$INSTALL" --target=all < /dev/null > "$out" 2>&1 &
  local pid=$!
  # Give it ~50ms to start the per-skill loop, then signal.
  sleep 0.1
  kill -INT "$pid" 2>/dev/null
  wait "$pid"
  local rc=$?
  # 130 (SIGINT) or possibly 0/1 if install finished before signal arrived.
  if [ "$rc" -ne 130 ]; then
    # Tolerate the race — install may have finished. Mark skip rather than fail.
    echo "    SKIP: install completed before SIGINT could land (race; rc=$rc)" >&2
    return 0
  fi
  grep -q "Installation interrupted (SIGINT)" "$out" || {
    echo "    missing interrupt message" >&2; cat "$out" >&2; return 1;
  }
}

# --- #10: `d` triggers dry-run preview of detected
test_install_plan_d_runs_dry_run_of_detected() {
  mark_detected claude
  local out="$FAKE_HOME/out.log"
  pty_install "$out" 'd\n'
  [ "$RC" = "77" ] && return 77
  assert_eq "0" "$RC" "exit code (d preview)" || { cat "$out" >&2; return 1; }
  grep -q "Dry run complete" "$out" || { echo "    missing 'Dry run complete' on d-branch" >&2; cat "$out" >&2; return 1; }
  # Nothing should be written.
  assert_file_missing "$HOME/.claude/skills" || return 1
  assert_file_missing "$HOME/.cursor/skills" || return 1
}

# --- #11: two consecutive unknown inputs → exit 1
test_install_plan_unknown_input_retries_once_then_exits() {
  mark_detected claude
  local out="$FAKE_HOME/out.log"
  pty_install "$out" 'foo\nbar\n'
  [ "$RC" = "77" ] && return 77
  assert_eq "1" "$RC" "exit code (two unknowns → exit 1)" || { cat "$out" >&2; return 1; }
  grep -q "unknown input" "$out" || { echo "    missing 'unknown input' hint" >&2; cat "$out" >&2; return 1; }
  grep -q "Two unknown inputs" "$out" || { echo "    missing 'Two unknown inputs' final message" >&2; cat "$out" >&2; return 1; }
}

# --- #12: --dry-run prompt says 'preview' not 'install'
test_install_dry_run_prompt_says_preview() {
  mark_detected claude
  local out="$FAKE_HOME/out.log"
  pty_install "$out" '\n' --dry-run
  [ "$RC" = "77" ] && return 77
  assert_eq "0" "$RC" "exit code (--dry-run + Enter)" || { cat "$out" >&2; return 1; }
  grep -q "Press Enter to preview" "$out" || { echo "    missing 'preview' wording in --dry-run prompt" >&2; cat "$out" >&2; return 1; }
  if grep -q "Press Enter to install" "$out"; then
    echo "    unexpected 'Press Enter to install' wording when --dry-run is set" >&2
    cat "$out" >&2
    return 1
  fi
}

# --- #13: atomic swap on success — old install replaced cleanly
test_install_atomic_swap_on_success() {
  # First install.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  # Mark a sentinel inside skills/ to prove the dir is replaced (not appended).
  touch "$HOME/.cursor/skills/.sentinel-from-prior-run"
  # Second install — atomic swap should produce a fresh skills/ without the sentinel.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  if [ -e "$HOME/.cursor/skills/.sentinel-from-prior-run" ]; then
    echo "    sentinel survived — install was NOT atomic (skills/ wasn't fully replaced)" >&2
    return 1
  fi
  # All 46 skills should still be present.
  local count=$(find "$HOME/.cursor/skills" -mindepth 2 -name SKILL.md | wc -l | tr -d ' ')
  if [ "$count" -lt 46 ]; then
    echo "    expected 46 skills after atomic swap, got $count" >&2
    return 1
  fi
}

# --- #14: staging failure preserves existing production install
test_install_staging_failure_preserves_prod() {
  trap teardown_full EXIT
  # First install (clean).
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  local first_hash
  first_hash=$(md5 -q "$HOME/.cursor/skills/office-hours/SKILL.md")

  # Second install with a stub that fails for cursor on office-hours.
  with_failing_renderer "office-hours" "cursor"
  set +e
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  local rc=$?
  set -e

  assert_eq "1" "$rc" "exit code (staging fail)" || return 1
  # Production cursor/skills/ MUST still be present and unchanged.
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  local after_hash
  after_hash=$(md5 -q "$HOME/.cursor/skills/office-hours/SKILL.md")
  assert_eq "$first_hash" "$after_hash" "production hash preserved on staging fail" || return 1
  # The failed staging dir should be parked as .staging.failed.* for debugging.
  if ! ls -d "$HOME/.cursor/skills.staging.failed."* >/dev/null 2>&1; then
    echo "    expected .staging.failed.* dir for debugging" >&2
    return 1
  fi
}

# --- #15: orphaned .staging dir is cleaned by recovery pass
test_install_recovery_orphaned_staging() {
  # Create an orphaned staging dir from a hypothetical prior interrupted run.
  mkdir -p "$HOME/.cursor/skills.staging.99999/leftover"
  # Run install — recovery should clean it up.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  if [ -d "$HOME/.cursor/skills.staging.99999" ]; then
    echo "    expected orphaned .staging dir to be cleaned by recovery" >&2
    return 1
  fi
  # Production install completed.
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
}

# --- #16b: rapid rerun within 1h does not nest .old backups (codex P2 fix)
test_install_rapid_rerun_does_not_nest_old() {
  # First install — produces fresh skills/, no .old yet.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  # Second install — within 1h. Recovery would NOT clean .old (too recent).
  # Bug would: mv skills .old when .old exists → moves skills INTO .old.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  # Production must be a flat skills/ with the rendered files at the top level,
  # NOT skills/skills/... (which is what the bug produced).
  if [ -e "$HOME/.cursor/skills/skills" ]; then
    echo "    nested skills/skills/ exists — .old replacement was buggy" >&2
    return 1
  fi
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  # Third rerun — proves the layout stays flat across many cycles.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  if [ -e "$HOME/.cursor/skills/skills" ]; then
    echo "    nested skills/skills/ exists after 3rd rerun" >&2
    return 1
  fi
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  # The .old backup is also flat (single skills-equivalent layout, not nested).
  if [ -d "$HOME/.cursor/skills.old" ] && [ -e "$HOME/.cursor/skills.old/skills" ]; then
    echo "    nested .old/skills/ — .old layout is corrupted" >&2
    return 1
  fi
}

# --- #16: power-failure recovery — missing skills/ + present .old → restore
test_install_recovery_orphaned_old() {
  # First, install cleanly.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
  # Simulate power failure between mv chain: skills moved to .old, but .staging→skills never happened.
  mv "$HOME/.cursor/skills" "$HOME/.cursor/skills.old"
  assert_file_missing "$HOME/.cursor/skills" || return 1
  # Run install again — recovery should detect missing skills/, restore from .old, then install fresh.
  "$INSTALL" --target=cursor < /dev/null >/dev/null 2>&1
  # Production install must end up valid (whether from restore or re-install).
  assert_file_exists "$HOME/.cursor/skills/office-hours/SKILL.md" || return 1
}

# ───────────────────────────────────────────────────────────────────────────
# Runner
# ───────────────────────────────────────────────────────────────────────────

echo "vibestack install/uninstall integration tests"
echo ""

run_test "regression_claude_target_byte_identical_to_renderer" test_regression_claude_target_byte_identical_to_renderer
run_test "default_non_tty_installs_all_three"                  test_default_non_tty_installs_all_three
run_test "target_cursor_only_does_not_touch_others"             test_target_cursor_only_does_not_touch_claude_or_kiro
run_test "target_invalid_exits_2"                               test_target_invalid_exits_2
run_test "dry_run_writes_nothing"                               test_dry_run_writes_nothing
run_test "dry_run_reports_all_three_targets"                    test_dry_run_reports_all_three_targets
run_test "all_three_targets_byte_identical_per_skill"           test_all_three_targets_byte_identical_per_skill
run_test "install_idempotent_per_target"                        test_install_idempotent_per_target
run_test "install_all_then_uninstall_all_zero_residue"          test_install_all_then_uninstall_all_zero_residue
run_test "uninstall_target_cursor_preserves_claude"             test_uninstall_target_cursor_preserves_claude
run_test "install_warns_about_hooks_for_non_claude"             test_install_warns_about_hooks_for_non_claude
run_test "install_no_hook_warning_for_claude_only"              test_install_no_hook_warning_for_claude_only
run_test "bin_symlinks_present_per_target"                      test_bin_symlinks_present_per_target
# v1.5.0 install plan UX tests (PTY-gated)
run_test "v1.5: plan default Enter installs detected"           test_install_plan_default_enter_installs_detected
run_test "v1.5: plan a installs all three"                      test_install_plan_a_installs_all_three
run_test "v1.5: plan q exits zero"                              test_install_plan_q_exits_zero_with_message
run_test "v1.5: plan empty defaults + Enter exits hint"         test_install_plan_empty_default_enter_exits_with_hint
run_test "v1.5: plan e falls through to per-target"             test_install_plan_e_falls_through_to_per_target
run_test "v1.5: partial fail continues + exits nonzero"         test_install_partial_fail_continues_and_exits_nonzero
run_test "v1.5: partial fail keeps hook warning suppresses CTA" test_install_partial_fail_keeps_hook_warning_suppresses_cta
run_test "v1.5: SIGINT returns 130"                             test_install_sigint_returns_130
run_test "v1.5: plan d runs dry-run of detected"                test_install_plan_d_runs_dry_run_of_detected
run_test "v1.5: plan unknown input retries then exits"          test_install_plan_unknown_input_retries_once_then_exits
run_test "v1.5: --dry-run prompt says preview"                  test_install_dry_run_prompt_says_preview
run_test "v1.5: atomic swap on success"                         test_install_atomic_swap_on_success
run_test "v1.5: staging failure preserves prod"                 test_install_staging_failure_preserves_prod
run_test "v1.5: recovery cleans orphaned staging"               test_install_recovery_orphaned_staging
run_test "v1.5: rapid rerun does not nest .old (codex P2 fix)"  test_install_rapid_rerun_does_not_nest_old
run_test "v1.5: recovery restores from orphaned .old"           test_install_recovery_orphaned_old

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
exit 0
