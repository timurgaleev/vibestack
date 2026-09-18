#!/bin/bash
# Guards the RTK integration in the configuration phase.
#
# RTK installs by default (skip with --no-rtk / -R, parsed by ./install and
# handed to the library). Two regressions this locks down:
#  - `rtk init -g` must run AFTER the settings.json merge, or the merge (which is
#    repo-authoritative for the hooks map) clobbers the RTK PreToolUse hook every
#    sync.
#  - the installer must be downloaded to a file before running, not piped
#    straight to `sh` — `curl | sh` reports the shell's exit status, not curl's
#    (no pipefail), so a failed download would look like a successful install.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
INSTALL="$HERE/../lib/config-install.sh"
INSTALL_MAIN="$HERE/../install"

# R1: the skip flag is parsed by ./install and reaches the library. Both halves
# matter — a parsed flag that is never handed over is the same as no flag.
test_skip_flag() {
  if grep -q -- '--no-rtk|-R)' "$INSTALL_MAIN" \
     && grep -q 'CFG_RTK=false' "$INSTALL_MAIN" \
     && grep -q 'RTK="$CFG_RTK"' "$INSTALL_MAIN"; then
    _pass "R1: --no-rtk/-R sets CFG_RTK=false and is passed to the library"
  else
    _fail "R1: --no-rtk/-R does not reach the library as RTK=false"
  fi
}

# R2: rtk init runs AFTER the settings.json merge (hook survives each sync).
test_init_after_merge() {
  local merge_line init_line
  merge_line=$(grep -n 'Merging claude/settings.json' "$INSTALL" | head -1 | cut -d: -f1)
  init_line=$(grep -n '"$rtk_bin" init -g' "$INSTALL" | head -1 | cut -d: -f1)
  if [[ -n "$merge_line" && -n "$init_line" && "$init_line" -gt "$merge_line" ]]; then
    _pass "R2: rtk init ($init_line) comes after settings merge ($merge_line)"
  else
    _fail "R2: rtk init must run after the settings merge (merge=$merge_line init=$init_line)"
  fi
}

# R3: installer is downloaded to a file, never piped straight to sh.
test_no_pipe_to_sh() {
  if grep -q 'curl -fsSL "$RTK_INSTALL_URL" -o "$rtk_installer"' "$INSTALL"; then
    _pass "R3: RTK installer downloaded to a file before running"
  else
    _fail "R3: RTK installer is not downloaded to a file first"
  fi
}

# R4: an already-installed rtk skips the binary download (idempotent).
test_idempotent_skip() {
  if grep -q 'RTK already installed' "$INSTALL"; then
    _pass "R4: existing rtk binary skips re-install"
  else
    _fail "R4: no idempotency skip for an existing rtk binary"
  fi
}

# R5: rtk init runs non-interactively (--auto-patch + </dev/null), or the
# curl|bash one-liner hangs on rtk's settings.json patch prompt.
test_init_non_interactive() {
  if grep -q 'init -g --auto-patch </dev/null' "$INSTALL"; then
    _pass "R5: rtk init runs non-interactively"
  else
    _fail "R5: rtk init may block on an interactive prompt"
  fi
}

test_skip_flag
test_init_after_merge
test_no_pipe_to_sh
test_idempotent_skip
test_init_non_interactive
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
