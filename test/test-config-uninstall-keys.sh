#!/bin/bash
# Does `./uninstall --with-config` take back the keys the install merged in?
#
# The merge-managed files are co-owned: the repo contributes some keys, the user
# and the app own the rest. Until now uninstall removed only the files it had
# recorded and left every merged key behind, so removing the pack did not revoke
# the permissions it had been granted.
#
# These cases run the real ./install and ./uninstall against an isolated HOME,
# because the whole point is what a user's settings.json looks like afterwards.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/config-helpers.sh"

SANDBOXES=()
new_sandbox() {
  local d
  d="$(mktemp -d)" || return 1
  mkdir -p "$d/home/.claude"
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

run_install() {
  local sb="$1"; shift
  env HOME="$sb/home" XDG_STATE_HOME="$sb/state" MANIFEST_DIR="$sb/state/vibekit" \
      bash "$REPO/install" --only=config --no-rtk --target=claude "$@" >/dev/null 2>&1
}

run_uninstall() {
  local sb="$1"; shift
  env HOME="$sb/home" XDG_STATE_HOME="$sb/state" MANIFEST_DIR="$sb/state/vibekit" \
      bash "$REPO/uninstall" --target=claude --with-config "$@" 2>&1
}

SETTINGS() { printf '%s/home/.claude/settings.json' "$1"; }

# jq is not a dependency of this repo, so assertions go through python3 the way
# test-config-settings_merge.sh does.
jexpr() { # jexpr <file> <python expr over `d`> -> prints True/False
  python3 -c "
import json,sys
try:
    d=json.load(open('$1'))
except Exception:
    print('LOADFAIL'); sys.exit(0)
print($2)
" 2>/dev/null
}

assert_expr() { # assert_expr <file> <expr> <expected> <name>
  local got
  got="$(jexpr "$1" "$2")"
  if [[ "$got" == "$3" ]]; then _pass "$4"; else _fail "$4 (got '$got', wanted '$3')"; fi
}

# ---------------------------------------------------------------------------
# U1 — a settings.json that is entirely ours goes away completely
# ---------------------------------------------------------------------------
test_ours_alone_is_removed() {
  local sb; sb="$(new_sandbox)" || { _fail "U1: no sandbox"; return; }
  run_install "$sb"
  [[ -f "$(SETTINGS "$sb")" ]] || { _fail "U1: install did not create settings.json"; return; }

  run_uninstall "$sb" >/dev/null
  assert_absent "$(SETTINGS "$sb")" "U1: a settings.json with nothing of yours in it is removed"
}

# ---------------------------------------------------------------------------
# U2 — the grant is revoked, the user's own entries are not
#
# This is the case the whole change exists for: Bash(*) is unioned into an
# allow-list the user already had, so removing the pack has to remove our entry
# and leave theirs.
# ---------------------------------------------------------------------------
test_grant_revoked_user_entries_kept() {
  local sb; sb="$(new_sandbox)" || { _fail "U2: no sandbox"; return; }
  cat > "$(SETTINGS "$sb")" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(mytool:*)"],
    "defaultMode": "default"
  },
  "model": "opus",
  "myOwnKey": {"nested": [1, 2, 3]}
}
JSON
  run_install "$sb"

  # Precondition: the merge really did grant it. Without this the test could
  # pass on a build where the merge never ran at all.
  assert_expr "$(SETTINGS "$sb")" "'Bash(*)' in d['permissions']['allow']" "True" \
    "U2a: precondition — the install granted Bash(*)"

  run_uninstall "$sb" >/dev/null
  local f; f="$(SETTINGS "$sb")"
  assert_expr "$f" "'Bash(*)' in d['permissions']['allow']" "False" \
    "U2b: Bash(*) is gone after uninstall"
  assert_expr "$f" "'Bash(mytool:*)' in d['permissions']['allow']" "True" \
    "U2c: the user's own allow entry survived"
  assert_expr "$f" "d.get('model')" "opus" \
    "U2d: an unrelated key the user set is untouched"
  assert_expr "$f" "d.get('myOwnKey',{}).get('nested')" "[1, 2, 3]" \
    "U2e: a nested structure the user owns is untouched"
}

# ---------------------------------------------------------------------------
# U3 — a value the repo overwrote is restored, not merely deleted
#
# deep_merge lets the repo win on a scalar the machine also set. Deleting it on
# uninstall would leave the user worse off than before they installed.
# ---------------------------------------------------------------------------
test_overwritten_value_is_restored() {
  local sb; sb="$(new_sandbox)" || { _fail "U3: no sandbox"; return; }
  cat > "$(SETTINGS "$sb")" <<'JSON'
{"theme": "dark", "permissions": {"defaultMode": "plan"}}
JSON
  run_install "$sb"
  assert_expr "$(SETTINGS "$sb")" "d.get('theme')" "auto" \
    "U3a: precondition — the repo overwrote theme"

  local out; out="$(run_uninstall "$sb")"
  assert_expr "$(SETTINGS "$sb")" "d.get('theme')" "dark" \
    "U3b: the user's original theme is back"
  assert_expr "$(SETTINGS "$sb")" "d.get('permissions',{}).get('defaultMode')" "plan" \
    "U3c: the user's original defaultMode is back"

  # The report is the only place the user learns a value was put back rather
  # than dropped. It is filtered with sed -E, and a BRE version of that filter
  # matches nothing on BSD sed while still printing the summary count — a
  # failure that looks like success unless something asserts on the line.
  if grep -q 'restored' <<<"$out"; then
    _pass "U3d: the report names the values it put back"
  else
    _fail "U3d: values were restored but the report did not say so"
  fi
}

# ---------------------------------------------------------------------------
# U4 — installing twice still leaves an uninstall that works
#
# The cumulative case. A record rewritten on every sync describes the state
# after sync 1, in which our keys are already present, and would conclude that
# none of them are ours.
# ---------------------------------------------------------------------------
test_two_installs_then_uninstall() {
  local sb; sb="$(new_sandbox)" || { _fail "U4: no sandbox"; return; }
  cat > "$(SETTINGS "$sb")" <<'JSON'
{"permissions": {"allow": ["Bash(mytool:*)"]}}
JSON
  run_install "$sb"
  run_install "$sb"
  run_uninstall "$sb" >/dev/null

  assert_expr "$(SETTINGS "$sb")" "'Bash(*)' in d['permissions']['allow']" "False" \
    "U4a: Bash(*) still removed after a second sync"
  assert_expr "$(SETTINGS "$sb")" "'Bash(mytool:*)' in d['permissions']['allow']" "True" \
    "U4b: the user's entry still survives after a second sync"
}

# ---------------------------------------------------------------------------
# U5 — a value the user changed after install is theirs now
# ---------------------------------------------------------------------------
test_user_edited_value_is_kept() {
  local sb; sb="$(new_sandbox)" || { _fail "U5: no sandbox"; return; }
  run_install "$sb"
  python3 - "$(SETTINGS "$sb")" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"]["defaultMode"] = "plan"   # the user changed their mind
json.dump(d, open(p, "w"), indent=2)
PY

  local out; out="$(run_uninstall "$sb")"
  assert_expr "$(SETTINGS "$sb")" "d.get('permissions',{}).get('defaultMode')" "plan" \
    "U5a: a value the user changed since install is left alone"
  if grep -qi "changed" <<<"$out"; then
    _pass "U5b: uninstall says it kept a key the user changed"
  else
    _fail "U5b: uninstall removed nothing but did not say why"
  fi
}

# ---------------------------------------------------------------------------
# U6 — a key the user deleted by hand is not an error
# ---------------------------------------------------------------------------
test_user_deleted_key_is_not_an_error() {
  local sb; sb="$(new_sandbox)" || { _fail "U6: no sandbox"; return; }
  cat > "$(SETTINGS "$sb")" <<'JSON'
{"model": "opus"}
JSON
  run_install "$sb"
  python3 - "$(SETTINGS "$sb")" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("statusLine", None)
json.dump(d, open(p, "w"), indent=2)
PY

  run_uninstall "$sb" >/dev/null
  local rc=$?
  [[ "$rc" -eq 0 ]] && _pass "U6a: uninstall exits 0 when one of our keys is already gone" \
                    || _fail "U6a: uninstall exited $rc"
  assert_expr "$(SETTINGS "$sb")" "d.get('model')" "opus" \
    "U6b: the user's key is still there"
}

# ---------------------------------------------------------------------------
# U7 — no python3 means nothing is removed, and the run says so
# ---------------------------------------------------------------------------
test_no_python_refuses() {
  local sb; sb="$(new_sandbox)" || { _fail "U7: no sandbox"; return; }
  cat > "$(SETTINGS "$sb")" <<'JSON'
{"permissions": {"allow": ["Bash(mytool:*)"]}}
JSON
  run_install "$sb"

  # A shim directory whose python3 does not exist. Resolve the real interpreter
  # first: a stub *named* python3 that re-execs by name would find itself.
  local shim="$sb/shim"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 127\n' > "$shim/python3"
  chmod +x "$shim/python3"

  local out
  out="$(env HOME="$sb/home" XDG_STATE_HOME="$sb/state" MANIFEST_DIR="$sb/state/vibekit" \
        PATH="$shim:$PATH" bash "$REPO/uninstall" --target=claude --with-config 2>&1)"

  # The file must be byte-identical to what the install left.
  if grep -q 'Bash(\*)' "$(SETTINGS "$sb")"; then
    _pass "U7a: without python3 the merged keys are left in place"
  else
    _fail "U7a: keys were removed without a parser to do it safely"
  fi
  if grep -qi "python3" <<<"$out"; then
    _pass "U7b: the run says why it could not take the keys back"
  else
    _fail "U7b: the refusal was silent"
  fi
}

# ---------------------------------------------------------------------------
# U8 — an unparseable settings.json is left exactly as it is
# ---------------------------------------------------------------------------
test_unparseable_destination_is_untouched() {
  local sb; sb="$(new_sandbox)" || { _fail "U8: no sandbox"; return; }
  run_install "$sb"
  printf '{ this is not json' > "$(SETTINGS "$sb")"
  local before; before="$(cat "$(SETTINGS "$sb")")"

  run_uninstall "$sb" >/dev/null
  if [[ "$(cat "$(SETTINGS "$sb")" 2>/dev/null)" == "$before" ]]; then
    _pass "U8: a settings.json that does not parse is left byte-identical"
  else
    _fail "U8: uninstall rewrote a file it could not read"
  fi
}

# ---------------------------------------------------------------------------
# U9 — an object we created and then emptied does not linger as {}
# ---------------------------------------------------------------------------
test_emptied_object_is_pruned() {
  local sb; sb="$(new_sandbox)" || { _fail "U9: no sandbox"; return; }
  cat > "$(SETTINGS "$sb")" <<'JSON'
{"model": "opus"}
JSON
  run_install "$sb"
  run_uninstall "$sb" >/dev/null
  assert_expr "$(SETTINGS "$sb")" "'permissions' in d" "False" \
    "U9a: the permissions object we created is gone, not left empty"
  assert_expr "$(SETTINGS "$sb")" "d.get('model')" "opus" \
    "U9b: the user's key kept the file alive"
}

# ---------------------------------------------------------------------------
# U10 — a value the user already had, identical to the one we ship, was never
# ours to take back
#
# The merge changes nothing in this case, so uninstall must not claim credit for
# removing it. Losing this distinction costs no data, but it makes the report
# lie about what the run did, which is the only thing the user has to go on.
# ---------------------------------------------------------------------------
test_value_that_matched_ours_is_not_claimed() {
  local sb; sb="$(new_sandbox)" || { _fail "U10: no sandbox"; return; }
  cat > "$(SETTINGS "$sb")" <<'JSON'
{"theme": "auto", "model": "opus"}
JSON
  run_install "$sb"
  local out; out="$(run_uninstall "$sb")"

  assert_expr "$(SETTINGS "$sb")" "d.get('theme')" "auto" \
    "U10a: the value the user already had is still there"
  if grep -Eq '^\s+- theme\b' <<<"$out"; then
    _fail "U10b: uninstall claimed a key it never introduced"
  else
    _pass "U10b: uninstall did not claim a key it never introduced"
  fi
}

echo "uninstall --with-config: merged keys"
test_ours_alone_is_removed
test_grant_revoked_user_entries_kept
test_overwritten_value_is_restored
test_two_installs_then_uninstall
test_user_edited_value_is_kept
test_user_deleted_key_is_not_an_error
test_no_python_refuses
test_unparseable_destination_is_untouched
test_emptied_object_is_pruned
test_value_that_matched_ours_is_not_claimed

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
