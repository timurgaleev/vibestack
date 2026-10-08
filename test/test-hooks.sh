#!/usr/bin/env bash
# test-hooks.sh — regression tests for the PreToolUse safety hooks.
#
# Every case here is a bug that shipped: a decision Claude Code silently
# discarded, a destructive command that slipped past the extractor, a boundary
# that failed open. The assertions are on the WIRE FORMAT as much as the
# verdict, because the format is where the silence came from.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAREFUL="$ROOT/skills/careful/bin/check-careful.sh"
FREEZE="$ROOT/skills/freeze/bin/check-freeze.sh"
FREEZE_STATE="$ROOT/skills/freeze/bin/freeze-state.sh"

PASS=0
FAIL=0

# Isolate state and analytics from the operator's real ~/.vibestack.
TMPHOME=$(mktemp -d)
export VIBESTACK_HOME="$TMPHOME/state"
mkdir -p "$VIBESTACK_HOME"
trap 'rm -rf "$TMPHOME"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }

# assert_decision NAME SCRIPT PAYLOAD EXPECTED
#   EXPECTED is "allow", "ask" or "deny". An ask/deny must arrive nested under
#   hookSpecificOutput — a top-level permissionDecision is exactly the no-op
#   this suite exists to catch, so it is scored as a failure, not a pass.
assert_decision() {
  local name="$1" script="$2" payload="$3" expected="$4"
  local out
  out=$(printf '%s' "$payload" | bash "$script" 2>/dev/null)

  if [ "$expected" = "allow" ]; then
    if [ "$out" = "{}" ]; then ok "$name"; else bad "$name" "{}" "$out"; fi
    return
  fi

  case "$out" in
    '{}')
      bad "$name" "$expected decision" "{} (allowed)" ;;
    '{"hookSpecificOutput":'*'"permissionDecision":"'"$expected"'"'*)
      ok "$name" ;;
    '{"permissionDecision"'*)
      bad "$name" "$expected nested under hookSpecificOutput" "top-level permissionDecision (Claude Code ignores this)" ;;
    *)
      bad "$name" "$expected decision" "$out" ;;
  esac
}

# assert_valid_json NAME PAYLOAD — the emitted envelope must parse.
assert_valid_json() {
  local name="$1" script="$2" payload="$3" out
  out=$(printf '%s' "$payload" | bash "$script" 2>/dev/null)
  if printf '%s' "$out" | python3 -c 'import sys,json; json.loads(sys.stdin.read())' 2>/dev/null; then
    ok "$name"
  else
    bad "$name" "parseable JSON" "$out"
  fi
}

echo "careful — allow tier"
assert_decision "build artifacts pass"          "$CAREFUL" '{"tool_input":{"command":"rm -rf node_modules"}}' allow
assert_decision "capital -R build artifacts"    "$CAREFUL" '{"tool_input":{"command":"rm -Rf dist"}}' allow
assert_decision "non-Bash payload passes"       "$CAREFUL" '{"tool_input":{"file_path":"/tmp/x"}}' allow
assert_decision "harmless command passes"       "$CAREFUL" '{"tool_input":{"command":"ls -la"}}' allow

echo "careful — ask tier"
assert_decision "recursive delete asks"         "$CAREFUL" '{"tool_input":{"command":"rm -rf /var/important"}}' ask
assert_decision "SQL DROP asks"                 "$CAREFUL" '{"tool_input":{"command":"psql -c \"DROP TABLE users\""}}' ask
assert_decision "SQL TRUNCATE asks"             "$CAREFUL" '{"tool_input":{"command":"psql -c \"TRUNCATE orders\""}}' ask
assert_decision "git reset --hard asks"         "$CAREFUL" '{"tool_input":{"command":"git reset --hard HEAD~3"}}' ask
assert_decision "kubectl delete asks"           "$CAREFUL" '{"tool_input":{"command":"kubectl delete pod web-0"}}' ask
assert_decision "docker prune asks"             "$CAREFUL" '{"tool_input":{"command":"docker system prune -a"}}' ask
assert_decision "force-with-lease asks not deny" "$CAREFUL" '{"tool_input":{"command":"git push --force-with-lease origin main"}}' ask

echo "careful — escaped-quote extractor (the bypass)"
# grep -o '"command":"[^"]*"' truncates at the first escaped quote, so each of
# these reached the pattern checks as a harmless prefix and returned {}.
assert_decision "quoted arg then rm -rf /"      "$CAREFUL" '{"tool_input":{"command":"git commit -m \"wip\" && rm -rf /"}}' ask
assert_decision "bash -c \"rm -rf /\""          "$CAREFUL" '{"tool_input":{"command":"bash -c \"rm -rf /\""}}' ask
assert_decision "echo then rm -rf ~"            "$CAREFUL" '{"tool_input":{"command":"echo \"x\"; rm -rf ~"}}' ask

echo "careful — deny tier"
assert_decision "rm -rf / denied"               "$CAREFUL" '{"tool_input":{"command":"rm -rf /"}}' deny
assert_decision "rm -rf ~ denied"               "$CAREFUL" '{"tool_input":{"command":"rm -rf ~"}}' deny
assert_decision "sudo rm -rf / denied"          "$CAREFUL" '{"tool_input":{"command":"sudo rm -rf /"}}' deny
assert_decision "quoted rm -rf \"/\" denied"    "$CAREFUL" '{"tool_input":{"command":"rm -rf \"/\""}}' deny
# Compound commands are not eligible for the deny tier — they fall back to ask.
assert_decision "compound rm falls back to ask" "$CAREFUL" '{"tool_input":{"command":"cd /tmp && rm -rf /"}}' ask

echo "careful — force-push destinations, standing on the default branch"
# The deny needs the current branch to BE the default, so build a throwaway repo
# rather than depending on whatever branch the suite happens to run from.
FORCE_REPO="$TMPHOME/force-repo"
mkdir -p "$FORCE_REPO"
(
  cd "$FORCE_REPO"
  git init -q -b main .
  git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  git remote add origin https://example.com/x.git
  git update-ref refs/remotes/origin/main HEAD
) >/dev/null 2>&1

assert_decision_in() {
  local dir="$1" name="$2" payload="$3" expected="$4" out
  out=$(cd "$dir" && printf '%s' "$payload" | bash "$CAREFUL" 2>/dev/null)
  case "$out" in
    '{}') [ "$expected" = allow ] && ok "$name" || bad "$name" "$expected" "{} (allowed)" ;;
    '{"hookSpecificOutput":'*'"permissionDecision":"'"$expected"'"'*) ok "$name" ;;
    *) bad "$name" "$expected decision" "$out" ;;
  esac
}

# Every case below needs the repo to HAVE a default branch: the hook resolves it
# from origin/HEAD (falling back to origin/main / origin/master), and a CI
# checkout has none — which is why these have to run in the built repo, not
# wherever the suite happens to be invoked from.
#
# A leading + on the refspec carries force with no flag at all, and a fully
# qualified destination is the same push as the short branch name.
assert_decision_in "$FORCE_REPO" "+HEAD:refs/heads/main denied" '{"tool_input":{"command":"git push origin +HEAD:refs/heads/main"}}' deny
assert_decision_in "$FORCE_REPO" "+main denied"                 '{"tool_input":{"command":"git push origin +main"}}' deny
assert_decision_in "$FORCE_REPO" "-f refs/heads/main denied"    '{"tool_input":{"command":"git push -f origin refs/heads/main"}}' deny
assert_decision_in "$FORCE_REPO" "+feature asks not denies"     '{"tool_input":{"command":"git push origin +feature"}}' ask
assert_decision_in "$FORCE_REPO" "ordinary push passes"         '{"tool_input":{"command":"git push origin main"}}' allow
# A remote name is not a target: `git push --force origin` still force-pushes the
# current branch's upstream, which is the default branch when you are on it.
assert_decision_in "$FORCE_REPO" "bare --force denied"        '{"tool_input":{"command":"git push --force"}}' deny
assert_decision_in "$FORCE_REPO" "--force origin denied"      '{"tool_input":{"command":"git push --force origin"}}' deny
assert_decision_in "$FORCE_REPO" "-f origin denied"           '{"tool_input":{"command":"git push -f origin"}}' deny
assert_decision_in "$FORCE_REPO" "--force origin main denied" '{"tool_input":{"command":"git push --force origin main"}}' deny
# A feature branch is not the catastrophic case, and lease is the safe variant.
assert_decision_in "$FORCE_REPO" "--force origin feature asks" '{"tool_input":{"command":"git push --force origin feature"}}' ask
assert_decision_in "$FORCE_REPO" "--force-with-lease asks"     '{"tool_input":{"command":"git push --force-with-lease origin"}}' ask

echo "careful — the home directory written out in full"
assert_decision "rm -rf \$HOME denied"          "$CAREFUL" "{\"tool_input\":{\"command\":\"rm -rf $HOME\"}}" deny
assert_decision "someone else's home only asks" "$CAREFUL" '{"tool_input":{"command":"rm -rf /Users/not-the-current-user"}}' ask

echo "careful — obfuscation and unreadable input"
assert_decision "IFS word-splitting asks"       "$CAREFUL" '{"tool_input":{"command":"rm${IFS}-rf${IFS}/"}}' ask
assert_decision "base64-to-shell asks"          "$CAREFUL" '{"tool_input":{"command":"echo cm0gLXJmIC8= | base64 -d | bash"}}' ask
assert_decision "unparseable payload asks"      "$CAREFUL" 'this is not json' ask
# Empty stdin is unreadable too — a real PreToolUse call always carries a payload.
assert_decision "empty stdin asks"              "$CAREFUL" '' ask

echo "freeze — no boundary configured"
rm -f "$VIBESTACK_HOME/freeze-dir.txt"
assert_decision "no state file allows"          "$FREEZE" '{"tool_input":{"file_path":"/tmp/anything.txt"}}' allow

echo "freeze — boundary enforcement"
FZ="$TMPHOME/fz"
mkdir -p "$FZ/in" "$FZ/out"
echo target > "$FZ/out/target.txt"
ln -sf "$FZ/out/target.txt" "$FZ/in/link.txt"
# Resolve through any /tmp -> /private/tmp symlink so the boundary string matches.
printf '%s\n' "$(cd "$FZ/in" && pwd -P)" > "$VIBESTACK_HOME/freeze-dir.txt"

assert_decision "inside boundary allowed"       "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/in/new.txt\"}}" allow
assert_decision "outside boundary denied"       "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/out/target.txt\"}}" deny
# A symlink whose final component points outside: resolving only the parent
# directory judged this in-boundary while the write landed outside.
assert_decision "escaping symlink denied"       "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/in/link.txt\"}}" deny
assert_decision "parent traversal denied"       "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/in/../out/target.txt\"}}" deny
# The hook only runs on Edit/Write/NotebookEdit, so a payload with no path is a
# schema it cannot check — deny rather than wave it through.
assert_decision "payload with no path denied"   "$FREEZE" '{"tool_input":{"command":"ls"}}' deny
# Deny tier: unreadable input must block, the opposite of careful's ask.
assert_decision "unparseable payload denied"    "$FREEZE" 'this is not json' deny
assert_decision "empty stdin denied"            "$FREEZE" '' deny

echo "freeze — NotebookEdit carries notebook_path"
# Reading file_path alone parsed a notebook edit as "no path" and allowed it.
assert_decision "notebook outside denied"       "$FREEZE" "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$FZ/out/x.ipynb\",\"new_source\":\"x\"}}" deny
assert_decision "notebook inside allowed"       "$FREEZE" "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$FZ/in/x.ipynb\",\"new_source\":\"x\"}}" allow
for _skill in freeze guard investigate; do
  if grep -q 'matcher: "NotebookEdit"' "$ROOT/skills/$_skill/SKILL.md"; then
    ok "$_skill registers a NotebookEdit matcher"
  else
    bad "$_skill registers a NotebookEdit matcher" 'matcher: "NotebookEdit"' "missing"
  fi
done

echo "freeze — unexpected failures deny (EXIT backstop)"
# An unreadable state file made the read pipeline fail under set -e: exit 1, no
# JSON, which Claude Code treats as non-blocking — the edit went through.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$VIBESTACK_HOME/freeze-dir.txt"
  assert_decision "unreadable state file denied"  "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/out/target.txt\"}}" deny
  assert_valid_json "unreadable state: one JSON object" "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/out/target.txt\"}}"
  chmod 644 "$VIBESTACK_HOME/freeze-dir.txt"
else
  echo "  skip unreadable state file (running as root)"
fi

echo "freeze — relative saved boundary is ambiguous"
printf 'src/auth/\n' > "$VIBESTACK_HOME/freeze-dir.txt"
assert_decision "relative boundary denied"      "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/in/a.txt\"}}" deny

echo "freeze-state — the shared writer"
rm -f "$VIBESTACK_HOME/freeze-dir.txt"
# A mistyped path used to resolve to "" and then to "/", which contains every
# path: the boundary was announced as set while allowing every edit.
if bash "$FREEZE_STATE" set "$FZ/no-such-dir" >/dev/null 2>&1; then
  bad "typo path refused" "non-zero exit" "exit 0"
else
  ok "typo path refused"
fi
[ ! -e "$VIBESTACK_HOME/freeze-dir.txt" ] && ok "typo path writes no state" || bad "typo path writes no state" "no state file" "$(cat "$VIBESTACK_HOME/freeze-dir.txt")"
if bash "$FREEZE_STATE" set / >/dev/null 2>&1; then
  bad "root refused as a boundary" "non-zero exit" "exit 0"
else
  ok "root refused as a boundary"
fi
[ ! -e "$VIBESTACK_HOME/freeze-dir.txt" ] && ok "root refusal writes no state" || bad "root refusal writes no state" "no state file" "$(cat "$VIBESTACK_HOME/freeze-dir.txt")"

# set: relative input lands as an absolute physical path, and the hook enforces it.
_out=$(cd "$FZ" && bash "$FREEZE_STATE" set in 2>&1)
_want="$(cd "$FZ/in" && pwd -P)"
[ "$(sed -n 1p "$VIBESTACK_HOME/freeze-dir.txt")" = "$_want" ] && ok "set writes the absolute physical path" || bad "set writes the absolute physical path" "$_want" "$(sed -n 1p "$VIBESTACK_HOME/freeze-dir.txt")"
case "$_out" in *"FREEZE_DIR=$_want"*) ok "set reports FREEZE_DIR" ;; *) bad "set reports FREEZE_DIR" "FREEZE_DIR=$_want" "$_out" ;; esac
assert_decision "set boundary: inside allowed"  "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/in/a.txt\"}}" allow
assert_decision "set boundary: outside denied"  "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/out/target.txt\"}}" deny
# A failed set must leave the existing boundary exactly as it was.
_before=$(cat "$VIBESTACK_HOME/freeze-dir.txt")
bash "$FREEZE_STATE" set "$FZ/typo" >/dev/null 2>&1 || true
[ "$(cat "$VIBESTACK_HOME/freeze-dir.txt")" = "$_before" ] && ok "failed set keeps the boundary" || bad "failed set keeps the boundary" "$_before" "$(cat "$VIBESTACK_HOME/freeze-dir.txt")"

# acquire over a user boundary: preserved, and the user's boundary survives.
_out=$(bash "$FREEZE_STATE" acquire "$FZ/out" 2>&1)
case "$_out" in FREEZE_PRESERVED*) ok "acquire preserves a user boundary" ;; *) bad "acquire preserves a user boundary" "FREEZE_PRESERVED" "$_out" ;; esac
[ "$(cat "$VIBESTACK_HOME/freeze-dir.txt")" = "$_before" ] && ok "user boundary intact after acquire" || bad "user boundary intact after acquire" "$_before" "$(cat "$VIBESTACK_HOME/freeze-dir.txt")"
_out=$(bash "$FREEZE_STATE" release 0123456789abcdef0123456789abcdef 2>&1)
[ "$(cat "$VIBESTACK_HOME/freeze-dir.txt")" = "$_before" ] && ok "foreign release keeps the user boundary" || bad "foreign release keeps the user boundary" "$_before" "$_out"

# acquire with no boundary: owned lock, released by its own token only.
bash "$FREEZE_STATE" clear >/dev/null
_out=$(bash "$FREEZE_STATE" acquire "$FZ/in" 2>&1)
_owner=$(printf '%s\n' "$_out" | sed -n 's/^FREEZE_OWNER=//p')
[ "${#_owner}" -eq 32 ] && ok "acquire returns a 32-hex owner token" || bad "acquire returns a 32-hex owner token" "FREEZE_OWNER=<32 hex>" "$_out"
assert_decision "acquired boundary enforced"    "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/out/target.txt\"}}" deny
bash "$FREEZE_STATE" release ffffffffffffffffffffffffffffffff >/dev/null 2>&1
[ -f "$VIBESTACK_HOME/freeze-dir.txt" ] && ok "wrong token does not release" || bad "wrong token does not release" "state kept" "state removed"
_out=$(bash "$FREEZE_STATE" release "$_owner" 2>&1)
[ ! -e "$VIBESTACK_HOME/freeze-dir.txt" ] && ok "owner token releases its lock" || bad "owner token releases its lock" "state removed" "$_out"
# The user replaced the lock mid-investigation: the stale token must not remove it.
_out=$(bash "$FREEZE_STATE" acquire "$FZ/in" 2>&1)
_owner=$(printf '%s\n' "$_out" | sed -n 's/^FREEZE_OWNER=//p')
bash "$FREEZE_STATE" set "$FZ/out" >/dev/null
bash "$FREEZE_STATE" release "$_owner" >/dev/null 2>&1
[ -f "$VIBESTACK_HOME/freeze-dir.txt" ] && ok "release spares a replacement boundary" || bad "release spares a replacement boundary" "state kept" "state removed"
if bash "$FREEZE_STATE" release 'not-a-token' >/dev/null 2>&1; then
  bad "malformed token rejected" "non-zero exit" "exit 0"
else
  ok "malformed token rejected"
fi
bash "$FREEZE_STATE" clear >/dev/null
[ ! -e "$VIBESTACK_HOME/freeze-dir.txt" ] && ok "clear removes the boundary" || bad "clear removes the boundary" "no state file" "state kept"
[ ! -e "$VIBESTACK_HOME/.freeze-mutation.lock" ] && ok "writer releases its mutex" || bad "writer releases its mutex" "no lock dir" "lock left behind"

# Every skill that sets or clears a boundary goes through the writer.
for _skill in freeze guard investigate unfreeze; do
  if grep -Eq '(>|rm -f).*freeze-dir\.txt' "$ROOT/skills/$_skill/SKILL.md"; then
    bad "$_skill writes state only via freeze-state.sh" "no direct write" "$(grep -E '(>|rm -f).*freeze-dir\.txt' "$ROOT/skills/$_skill/SKILL.md")"
  else
    ok "$_skill writes state only via freeze-state.sh"
  fi
done

echo "freeze — boundary paths that broke the old parser"
mkdir -p "$FZ/My Project"
printf '%s\n' "$(cd "$FZ/My Project" && pwd -P)" > "$VIBESTACK_HOME/freeze-dir.txt"
assert_decision "internal space: inside"        "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/My Project/a.txt\"}}" allow
assert_decision "internal space: outside"       "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/out/target.txt\"}}" deny
# A quote in the path used to produce malformed JSON, which discarded the deny.
assert_valid_json "quote in path stays valid JSON" "$FREEZE" "{\"tool_input\":{\"file_path\":\"$FZ/out/a\\\"b.txt\"}}"

echo "freeze — root as the boundary"
# / is its own dirname and basename, so naive resolution rebuilt it as "//" and
# the containment pattern became "//"* — a freeze on / denied every edit.
printf '/\n' > "$VIBESTACK_HOME/freeze-dir.txt"
assert_decision "root boundary contains all"    "$FREEZE" '{"tool_input":{"file_path":"/etc/hosts"}}' allow
assert_decision "root boundary contains home"   "$FREEZE" "{\"tool_input\":{\"file_path\":\"$HOME/x.txt\"}}" allow

echo "freeze — missing shared helper fails closed"
# Copy the skill tree into the sandbox and delete the helper THERE. Renaming the
# tracked file in place races with a concurrent run, and an interrupt between
# the two moves would leave the working tree without its helper.
BROKEN="$TMPHOME/broken-install"
mkdir -p "$BROKEN/careful/bin" "$BROKEN/freeze/bin"
cp "$ROOT/skills/careful/bin/check-careful.sh" "$BROKEN/careful/bin/"
cp "$ROOT/skills/freeze/bin/check-freeze.sh" "$BROKEN/freeze/bin/"
# hook-extract.sh is deliberately NOT copied — that is the condition under test.
printf '/\n' > "$VIBESTACK_HOME/freeze-dir.txt"
assert_decision "helper missing denies"         "$BROKEN/freeze/bin/check-freeze.sh" "{\"tool_input\":{\"file_path\":\"$FZ/out/target.txt\"}}" deny
assert_decision "helper missing: careful asks"  "$BROKEN/careful/bin/check-careful.sh" '{"tool_input":{"command":"ls"}}' ask

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
