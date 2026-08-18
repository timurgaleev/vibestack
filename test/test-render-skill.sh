#!/usr/bin/env bash
# test-render-skill — fixture-driven regression suite for bin/vibe-render-skill.
# Each fixture under test/fixtures/render/<name>/ is one test case.

set -u  # not -e: we rely on probing exit codes
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RENDER="$REPO_ROOT/bin/vibe-render-skill"
FIXTURES="$SCRIPT_DIR/fixtures/render"

PASS=0
FAIL=0
FAILS=()

pass() { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILS+=("$1: $2"); printf '  FAIL %s — %s\n' "$1" "$2"; }

# Locate source.md inside a fixture (under skills/<anything>/SKILL.md).
find_source() {
  local fix="$1"
  local f
  f="$(find "$fix/skills" -name SKILL.md 2>/dev/null | head -1)"
  if [ -n "$f" ]; then echo "$f"; return 0; fi
  # Fallback: source.md in fixture root (used by 00-plain).
  [ -f "$fix/source.md" ] && { echo "$fix/source.md"; return 0; }
  echo ""
}

run_render_fixture() {
  local fix="$1"
  local name; name="$(basename "$fix")"
  local source; source="$(find_source "$fix")"
  local expected_exit="0"
  [ -f "$fix/expected_exit" ] && expected_exit="$(tr -d '[:space:]' < "$fix/expected_exit")"

  if [ -z "$source" ]; then
    fail "$name" "no source file found"
    return
  fi

  local tmpdir; tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/vibe-test.XXXXXX")"
  trap 'rm -rf "$tmpdir"' RETURN
  local dest="$tmpdir/SKILL.md"

  # Run the renderer with the fixture as REPO_ROOT so snippets resolve to fixture's lib/snippets/.
  set +e
  VIBESTACK_REPO_ROOT="$fix" "$RENDER" "$source" "$dest" 2>"$tmpdir/stderr"
  local rc=$?
  set -e

  if [ "$rc" != "$expected_exit" ]; then
    fail "$name" "expected exit $expected_exit, got $rc. stderr: $(cat "$tmpdir/stderr")"
    rm -rf "$tmpdir"; return
  fi

  if [ "$expected_exit" = "0" ] && [ -f "$fix/expected.md" ]; then
    if ! diff -q "$dest" "$fix/expected.md" >/dev/null 2>&1; then
      fail "$name" "rendered output differs from expected.md"
      diff -u "$fix/expected.md" "$dest" | head -20 >&2
      rm -rf "$tmpdir"; return
    fi
  fi

  if [ -f "$fix/expected_sidecar_parts.txt" ]; then
    local sidecar="$tmpdir/.vibe-render.json"
    if [ ! -f "$sidecar" ]; then
      fail "$name" "expected sidecar at $sidecar but none was written"
      rm -rf "$tmpdir"; return
    fi
    local actual; actual="$(awk -v RS='"' 'NR % 2 == 0 && /^lib\/snippets\// {print}' "$sidecar" | sort -u)"
    local want; want="$(sort -u "$fix/expected_sidecar_parts.txt")"
    if [ "$actual" != "$want" ]; then
      fail "$name" "sidecar parts mismatch: want [$want] got [$actual]"
      rm -rf "$tmpdir"; return
    fi
  fi

  rm -rf "$tmpdir"
  pass "$name"
}

run_check_fixture() {
  local fix="$1"
  local name; name="$(basename "$fix")"
  local source; source="$(find_source "$fix")"
  local installed="$fix/installed.md"
  local expected_exit; expected_exit="$(tr -d '[:space:]' < "$fix/expected_check_exit")"

  set +e
  VIBESTACK_REPO_ROOT="$fix" "$RENDER" --check "$source" "$installed" >/dev/null 2>&1
  local rc=$?
  set -e

  if [ "$rc" != "$expected_exit" ]; then
    fail "$name" "(--check) expected exit $expected_exit, got $rc"
    return
  fi
  pass "$name"
}

run_idempotency_fixture() {
  local fix="$1"
  local name; name="$(basename "$fix")"
  local source; source="$(find_source "$fix")"
  local tmpdir; tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/vibe-test.XXXXXX")"

  set +e
  VIBESTACK_REPO_ROOT="$fix" "$RENDER" "$source" "$tmpdir/r1.md" 2>/dev/null
  local rc1=$?
  VIBESTACK_REPO_ROOT="$fix" "$RENDER" "$tmpdir/r1.md" "$tmpdir/r2.md" 2>/dev/null
  local rc2=$?
  set -e

  if [ "$rc1" != "0" ] || [ "$rc2" != "0" ]; then
    fail "$name" "render or re-render failed (rc1=$rc1 rc2=$rc2)"
    rm -rf "$tmpdir"; return
  fi

  if ! diff -q "$tmpdir/r1.md" "$tmpdir/r2.md" >/dev/null 2>&1; then
    fail "$name" "re-render is not byte-identical"
    rm -rf "$tmpdir"; return
  fi
  rm -rf "$tmpdir"
  pass "$name"
}

run_arg_parsing_fixture() {
  local name="12-arg-parsing"
  # Each invocation must exit 2.
  local cases=(
    "no_args"          # ""
    "one_arg foo"
    "three_args a b c"
    "unknown_flag --bogus a b"
    "check_one_arg --check foo"
  )
  for case_def in "${cases[@]}"; do
    local label="${case_def%% *}"
    local args="${case_def#* }"
    [ "$args" = "$case_def" ] && args=""
    set +e
    eval "$RENDER $args" >/dev/null 2>&1
    local rc=$?
    set -e
    if [ "$rc" != "2" ]; then
      fail "$name/$label" "expected exit 2, got $rc"
      continue
    fi
    pass "$name/$label"
  done
}

# ── infra-error harness (13-infra-errors) ─────────────────────────────────
# The renderer's `exit 3` guards only fire when mktemp/mv fail. Shim both onto
# PATH so the failure is forced rather than simulated — every call a case does
# not target still reaches the real binary.
INFRA_NAME=""
INFRA_FIX=""
INFRA_TMP=""
INFRA_SHIMS=""

make_infra_shims() {
  local real_mktemp real_mv
  real_mktemp="$(command -v mktemp)"
  real_mv="$(command -v mv)"
  mkdir -p "$INFRA_SHIMS"
  cat > "$INFRA_SHIMS/mktemp" <<EOF
#!/usr/bin/env bash
# Fails only under FAIL_MKTEMP=1; FAIL_MKTEMP_MATCH narrows it to one template.
if [ "\${FAIL_MKTEMP:-0}" = "1" ]; then
  m="\${FAIL_MKTEMP_MATCH:-}"
  if [ -z "\$m" ]; then echo "mktemp: shim: forced failure" >&2; exit 1; fi
  for a in "\$@"; do
    case "\$a" in *"\$m"*) echo "mktemp: shim: forced failure" >&2; exit 1 ;; esac
  done
fi
exec "$real_mktemp" "\$@"
EOF
  cat > "$INFRA_SHIMS/mv" <<EOF
#!/usr/bin/env bash
if [ "\${FAIL_MV:-0}" = "1" ]; then echo "mv: shim: forced failure" >&2; exit 1; fi
exec "$real_mv" "\$@"
EOF
  chmod +x "$INFRA_SHIMS/mktemp" "$INFRA_SHIMS/mv"
}

# infra_case LABEL WANT_RC WANT_MSG [VAR=VAL ...] RENDERER ARGS...
# Seeds $INFRA_TMP/LABEL/SKILL.md with a sentinel, so "the destination was left
# alone" is asserted by content, not merely by exit code.
infra_case() {
  local label="$1" want_rc="$2" want_msg="$3"; shift 3
  local d="$INFRA_TMP/$label"
  mkdir -p "$d"
  printf 'SENTINEL\n' > "$d/SKILL.md"
  set +e
  env PATH="$INFRA_SHIMS:$PATH" VIBESTACK_REPO_ROOT="$INFRA_FIX" "$@" \
    >/dev/null 2>"$d/stderr"
  local rc=$?
  set -e
  if [ "$rc" != "$want_rc" ]; then
    fail "$INFRA_NAME/$label" "expected exit $want_rc, got $rc. stderr: $(cat "$d/stderr")"
    return
  fi
  if ! grep -q "$want_msg" "$d/stderr"; then
    fail "$INFRA_NAME/$label" "stderr missing '$want_msg': $(cat "$d/stderr")"
    return
  fi
  if [ "$(cat "$d/SKILL.md")" != "SENTINEL" ]; then
    fail "$INFRA_NAME/$label" "destination SKILL.md was overwritten or half-written"
    return
  fi
  local leftovers
  leftovers="$(find "$d" -maxdepth 1 -name '.SKILL.*' | wc -l | tr -d ' ')"
  if [ "$leftovers" != "0" ]; then
    fail "$INFRA_NAME/$label" "$leftovers renderer temp file(s) left in dest dir"
    return
  fi
  pass "$INFRA_NAME/$label"
}

run_infra_error_fixture() {
  local fix="$1"
  INFRA_FIX="$fix"
  INFRA_NAME="$(basename "$fix")"
  INFRA_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe-test.XXXXXX")"
  INFRA_SHIMS="$INFRA_TMP/shims"
  make_infra_shims

  local source; source="$(find_source "$fix")"
  if [ -z "$source" ]; then
    fail "$INFRA_NAME" "no source file found"
    rm -rf "$INFRA_TMP"; return
  fi
  local sd="/opt/vibe-test-skill-dir"   # never touched; only drives substitution

  # DEST_DIR is a regular file, so mkdir -p fails for any uid (root included).
  infra_case mkdir_dest_dir 3 "render: infra: cannot create dest dir" \
    "$RENDER" "$source" "$INFRA_TMP/mkdir_dest_dir/SKILL.md/SKILL.md"

  infra_case mktemp_check_tmpdir 3 "render: infra: cannot create temp dir for --check" \
    FAIL_MKTEMP=1 "$RENDER" --check "$source" "$INFRA_TMP/mktemp_check_tmpdir/SKILL.md"

  infra_case mktemp_dest_temp 3 "render: infra: cannot create temp file in" \
    FAIL_MKTEMP=1 "$RENDER" "$source" "$INFRA_TMP/mktemp_dest_temp/SKILL.md"

  infra_case mktemp_sub_temp 3 "render: infra: cannot create temp file for substitution" \
    FAIL_MKTEMP=1 FAIL_MKTEMP_MATCH=.SKILL.sub. \
    "$RENDER" --skill-dir "$sd" "$source" "$INFRA_TMP/mktemp_sub_temp/SKILL.md"

  infra_case mv_final 3 "render: infra: cannot move into" \
    FAIL_MV=1 "$RENDER" "$source" "$INFRA_TMP/mv_final/SKILL.md"

  infra_case mv_substitution 3 "render: infra: cannot replace temp file after substitution" \
    FAIL_MV=1 "$RENDER" --skill-dir "$sd" "$source" "$INFRA_TMP/mv_substitution/SKILL.md"

  rm -rf "$INFRA_TMP"
}

# Find renderer
[ -x "$RENDER" ] || { echo "renderer not found or not executable: $RENDER" >&2; exit 1; }

echo "== render fixtures =="
for fix in "$FIXTURES"/*/; do
  fix="${fix%/}"
  name="$(basename "$fix")"
  case "$name" in
    09-check-no-drift|10-check-with-drift)
      run_check_fixture "$fix"
      ;;
    07-idempotent-rerender)
      run_idempotency_fixture "$fix"
      ;;
    12-arg-parsing)
      run_arg_parsing_fixture
      ;;
    13-infra-errors)
      run_infra_error_fixture "$fix"
      ;;
    *)
      run_render_fixture "$fix"
      ;;
  esac
done

echo ""
echo "== summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '    %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
