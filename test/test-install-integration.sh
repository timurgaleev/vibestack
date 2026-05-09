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
}

teardown_fake_home() {
  if [ -n "${FAKE_HOME:-}" ] && [ -d "$FAKE_HOME" ]; then
    rm -rf "$FAKE_HOME"
  fi
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
