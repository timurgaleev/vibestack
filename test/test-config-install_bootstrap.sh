#!/bin/bash
# Guards how the configuration library finds its own files.
#
# Regression: the standalone installer used to `source "$SCRIPT_DIR/lib/<file>"`
# with SCRIPT_DIR derived from ${BASH_SOURCE[0]}. Under `bash -c "$(curl ...)"`
# BASH_SOURCE is empty, so it resolved to $HOME/lib/<file> and failed. The
# library now derives its repo root from its own ${BASH_SOURCE[0]} and sources
# the sync helpers from there, so the same class of bug would show up as a
# resolution that depends on the caller's working directory. These tests run
# the resolution rather than reading it.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
INSTALL="$HERE/../lib/config-install.sh"

# I1: the repo root resolves from the library's own location, not the caller's
# working directory, and the sync helpers load from there.
test_sources_from_repo_dir() {
  local out
  out=$(cd / && bash -c '
    set -uo pipefail
    source "'"$HERE"'/../lib/config-install.sh"
    printf "%s|%s" "$CFG_REPO_DIR" "$(type -t sync_append_managed)"
  ' 2>&1)
  local want
  want="$(cd "$HERE/.." && pwd)|function"
  if [[ "$out" == "$want" ]]; then
    _pass "I1: repo root and sync helpers resolve from the library's own path"
  else
    _fail "I1: resolution depends on the caller (got '$out', want '$want')"
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

# I3: ./install hands the library an explicit repo root rather than letting it
# guess, so a checkout in an unusual place still deploys from itself.
test_source_after_clone() {
  local main="$HERE/../install"
  if grep -q 'CFG_REPO_DIR="\$REPO_DIR"' "$main" \
     && grep -q 'PAYLOAD_DIR="\$REPO_DIR/config"' "$main"; then
    _pass "I3: ./install passes CFG_REPO_DIR and PAYLOAD_DIR explicitly"
  else
    _fail "I3: ./install does not hand the library its repo root"
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
