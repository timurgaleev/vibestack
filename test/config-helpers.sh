#!/bin/bash
# Minimal zero-dependency assert helpers + HOME sandbox for install.sh lib tests.

PASS=0
FAIL=0

# Quiet the lib's msg_* output during tests unless DEBUG_TESTS is set.
if [[ -z "${DEBUG_TESTS:-}" ]]; then
  msg_info() { :; }
  msg_done() { :; }
  msg_add()  { :; }
  msg_warn() { :; }
fi

_fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

_pass() {
  PASS=$((PASS + 1))
  echo "  ok:   $1"
}

assert_absent() {
  local path="$1" name="$2"
  if [[ -e "$path" ]]; then _fail "$name (still exists: $path)"; else _pass "$name"; fi
}

assert_present() {
  local path="$1" name="$2"
  if [[ -e "$path" ]]; then _pass "$name"; else _fail "$name (missing: $path)"; fi
}

# Create an isolated fake HOME for one test; echoes the path.
make_sandbox() {
  mktemp -d "${TMPDIR:-/tmp}/vibekit-test.XXXXXX"
}
