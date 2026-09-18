#!/bin/bash
# Guards the curl | bash bootstrap path of install.sh.
#
# Regression: install.sh used to `source "$SCRIPT_DIR/lib/<file>"` where
# SCRIPT_DIR derived from ${BASH_SOURCE[0]}. Under `bash -c "$(curl ...)"`
# BASH_SOURCE is empty, so it resolved to $HOME/lib/<file> and failed — and
# lib/ isn't even on disk before the repo is cloned. The fix sources from
# $REPO_DIR (the just-cloned repo), after the clone/pull step.
#
# The bug was first found through a lib/ file that no longer exists. lib/config-sync.sh
# is sourced the same way and carries the same regression, so the guards moved
# onto it rather than being deleted alongside the file that exposed it.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
INSTALL="$HERE/../lib/config-install.sh"

# I1: sources the lib from the cloned repo, not the script's own dir.
test_sources_from_repo_dir() {
  if grep -q 'source "$REPO_DIR/lib/config-sync.sh"' "$INSTALL"; then
    _pass "I1: sources lib/config-sync.sh from \$REPO_DIR"
  else
    _fail "I1: install.sh does not source lib/config-sync.sh from \$REPO_DIR"
  fi
}

# I2: the broken BASH_SOURCE/SCRIPT_DIR source pattern is gone, for any lib.
test_no_script_dir_source() {
  if grep -qE 'source "\$SCRIPT_DIR/lib/' "$INSTALL"; then
    _fail "I2: broken \$SCRIPT_DIR source still present"
  else
    _pass "I2: no \$SCRIPT_DIR-based source"
  fi
}

# I3: the source happens AFTER the repo is cloned/pulled (file exists by then).
test_source_after_clone() {
  local clone_line src_line
  clone_line=$(grep -n 'git clone "$REPO_URL"' "$INSTALL" | head -1 | cut -d: -f1)
  src_line=$(grep -n 'source "$REPO_DIR/lib/config-sync.sh"' "$INSTALL" | head -1 | cut -d: -f1)
  if [[ -n "$clone_line" && -n "$src_line" && "$src_line" -gt "$clone_line" ]]; then
    _pass "I3: source ($src_line) comes after clone ($clone_line)"
  else
    _fail "I3: source must come after the clone step (clone=$clone_line src=$src_line)"
  fi
}

# I4: a missing lib degrades instead of crashing the run.
test_missing_lib_guarded() {
  if grep -q 'SYNC_LIB_LOADED=false' "$INSTALL" &&
     grep -q 'lib/config-sync.sh missing' "$INSTALL"; then
    _pass "I4: a missing lib/config-sync.sh is handled, not fatal"
  else
    _fail "I4: no guard for a missing lib/config-sync.sh"
  fi
}

test_sources_from_repo_dir
test_no_script_dir_source
test_source_after_clone
test_missing_lib_guarded
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
