#!/usr/bin/env bash
# test-codex-verdict.sh — /codex grades every run before presenting it.
#
# A Codex run can exit 0 and still have reviewed nothing: its sandbox never
# started, every command it ran failed, or it says it could not read the diff,
# and the text it ends with is often "no issues found". The Output Validator in
# skills/codex/SKILL.md turns those into VERDICT: unavailable, and untagged
# review prose into VERDICT: unverified rather than a pass.
#
# The validator and the run blocks are extracted from the skill source and run
# against fixtures and a stub `codex` on PATH, so this fails when the skill text
# regresses, not only when a copy of it does.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${CODEX_SKILL:-$ROOT/skills/codex/SKILL.md}"  # CODEX_SKILL overrides the source
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# --- extract the validator --------------------------------------------------
VALIDATOR="$TMP/codex-verdict.py"
awk '/<<.VIBE_CODEX_VERDICT_PY.$/{on=1; next} /^VIBE_CODEX_VERDICT_PY$/{on=0} on' "$SKILL" > "$VALIDATOR"
if [ -s "$VALIDATOR" ] && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$VALIDATOR"; then
  ok "validator extracts from SKILL.md and parses"
else
  no "validator block missing or not valid Python"
  echo "$pass passed, $fail failed"; exit 1
fi

# verdict MODE EXIT TEXT STDERR EVENTS -> prints the VERDICT word
verdict() {
  printf '%s' "$3" > "$TMP/resp"; printf '%s' "$4" > "$TMP/err"; printf '%s' "$5" > "$TMP/ev"
  python3 "$VALIDATOR" --mode "$1" --exit "$2" --stderr "$TMP/err" --events "$TMP/ev" "$TMP/resp" \
    | sed -n 's/^VERDICT: //p' || true
}
expect() { # NAME WANT GOT
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want $2, got '${3}')"; fi
}

OK_CMD='{"type":"item.completed","item":{"type":"command_execution","command":"git diff","status":"completed","exit_code":0,"aggregated_output":"diff --git a/x b/x"}}'
BAD_CMD='{"type":"item.completed","item":{"type":"command_execution","command":"git diff","status":"failed","exit_code":1,"aggregated_output":"bwrap: No permissions to create new namespace"}}'
BAD_CMD_PLAIN='{"type":"item.completed","item":{"type":"command_execution","command":"git diff","status":"failed","exit_code":127,"aggregated_output":"permission denied"}}'

echo "validator: unavailable runs"
expect "sandbox not started (stderr) + 'no issues' -> unavailable" unavailable \
  "$(verdict review 0 'No issues found.' 'Error: sandbox was not started: landlock ruleset failed' '')"
expect "bwrap failure in command output -> unavailable" unavailable \
  "$(verdict review 0 'Looks clean. NO_FINDINGS' '' "$BAD_CMD")"
expect "every command failed -> unavailable" unavailable \
  "$(verdict answer 0 'Nothing to worry about.' '' "$BAD_CMD_PLAIN")"
expect "says it could not read the diff -> unavailable" unavailable \
  "$(verdict review 0 'I could not read the diff, but there are no issues.' '' '')"
expect "[P1] beside an unable-to-run admission keeps the findings" findings \
  "$(verdict review 0 $'[P1] SQL injection at a.rb:3\nI was unable to run commands for the tests.' '' '')"
expect "[P2] beside an unable-to-run admission is still unavailable" unavailable \
  "$(verdict review 0 $'[P2] naming\nI was unable to run commands for the tests.' '' '')"
expect "says sandbox could not start (answer mode) -> unavailable" unavailable \
  "$(verdict answer 0 'The sandbox failed to start, so I answered from memory.' '' '')"
expect "empty final message -> unavailable" unavailable \
  "$(verdict review 0 '' '' "$OK_CMD")"
expect "non-zero exit -> unavailable" unavailable \
  "$(verdict review 1 '[P2] nit' 'ERROR: model not supported' '')"
expect "unparseable exit status -> unavailable" unavailable \
  "$(verdict answer unknown 'An answer.' '' "$OK_CMD")"
expect "refusal -> unavailable" unavailable \
  "$(verdict answer 0 "I cannot review this request." '' "$OK_CMD")"
expect "refusal opening a review -> unavailable" unavailable \
  "$(verdict review 0 "I'm sorry, but I can't assist with that." '' "$OK_CMD")"

# An incidental command succeeding is not evidence the diff was read.
LS_OK='{"type":"item.completed","item":{"type":"command_execution","command":"ls","status":"completed","exit_code":0,"aggregated_output":"README.md"}}'
DIFF_BAD='{"type":"item.completed","item":{"type":"command_execution","command":"git diff main...HEAD","status":"failed","exit_code":128,"aggregated_output":"fatal: ambiguous argument"}}'
expect "ls ran, git diff failed, answer ends NO_FINDINGS -> unavailable" unavailable \
  "$(verdict review 0 $'I could not read the diff because `git diff` failed.\nNO_FINDINGS' '' "$LS_OK"$'\n'"$DIFF_BAD")"
expect "'git diff failed' after a successful command -> unavailable" unavailable \
  "$(verdict review 0 $'The git diff failed with an ambiguous argument, so I looked at the files.\nNO_FINDINGS' '' "$LS_OK"$'\n'"$DIFF_BAD")"
expect "'unable to run git' after a successful command -> unavailable" unavailable \
  "$(verdict review 0 $'[P3] typo in README\nI was unable to run git in this sandbox.' '' "$LS_OK")"
expect "transcript success does not mask a could-not-access-the-diff admission" unavailable \
  "$(verdict review 0 $'Could not access the diff.\nNO_FINDINGS' $'exec ls\n succeeded in 3ms:' '')"
expect "[P1] beside a diff-read failure after a successful command keeps the findings" findings \
  "$(verdict review 0 $'[P1] SQL injection at a.rb:3\nI could not read the diff for the rest.' '' "$LS_OK"$'\n'"$DIFF_BAD")"

echo "validator: hedges are not refusals"
expect "mid-answer 'I cannot access' hedge -> answered" answered \
  "$(verdict answer 0 'The function looks fine. I cannot access the production database, but locally the query plan is OK.' '' "$OK_CMD")"
expect "long answer opening with a hedge -> answered" answered \
  "$(verdict answer 0 "I can't access your environment, so this is from the code alone. $(printf 'The retry loop in client.py backs off exponentially and caps at five attempts. %.0s' 1 2 3 4 5 6 7 8)" '' "$OK_CMD")"
expect "[P2] review with a hedge -> clean" clean \
  "$(verdict review 0 $'[P2] minor naming.\nI can'"'"'t evaluate runtime performance without a profiler.' '' "$OK_CMD")"
expect "[P1] review with a hedge -> findings" findings \
  "$(verdict review 0 $'I cannot assess the deploy config.\n[P1] SQL injection at a.rb:3' '' "$OK_CMD")"
expect "answer discussing a sandbox mid-text, no commands -> answered" answered \
  "$(verdict answer 0 'The attack is limited. Without root the sandbox could not start for the attacker.' '' '')"

echo "validator: review grading"
expect "untagged prose is unverified, never clean" unverified \
  "$(verdict review 0 'I reviewed the change and it looks good. No issues.' '' "$OK_CMD")"
expect "[P1] -> findings" findings \
  "$(verdict review 0 $'- **[P1]** SQL injection at a.rb:3\n- [P2] naming' '' "$OK_CMD")"
expect "native P0: prefix -> findings" findings \
  "$(verdict review 0 $'P0: data loss in migrate()' '' "$OK_CMD")"
expect "only [P2] -> clean" clean \
  "$(verdict review 0 '[P2] consider renaming foo' '' "$OK_CMD")"
expect "explicit NO_FINDINGS line -> clean" clean \
  "$(verdict review 0 $'Checked auth and parsing.\nNO_FINDINGS' '' "$OK_CMD")"
expect "codex review transcript counts as execution evidence" clean \
  "$(verdict review 0 '[P3] typo' $'exec git diff\n succeeded in 12ms:' '')"
expect "discussing sandboxes after commands ran is still an answer" answered \
  "$(verdict answer 0 'The sandbox failed to start in your CI config; fix seccomp there.' '' "$OK_CMD")"

# --- structural checks on the skill text ---------------------------------------
echo "skill text"
calls=$(grep -cE '^[[:space:]]*_cx [0-9]+ codex (review|exec)' "$SKILL" || true)
isolated=$(grep -E '^[[:space:]]*_cx [0-9]+ codex (review|exec)' "$SKILL" | grep -c "skills.include_instructions=false" || true)
if [ "$calls" -ge 5 ] && [ "$calls" = "$isolated" ]; then ok "all $calls codex calls pass skills.include_instructions=false"
else no "skills isolation flag on $isolated of $calls codex calls"; fi
execs=$(grep -cE '^[[:space:]]*_cx [0-9]+ codex exec' "$SKILL" || true)
with_o=$(grep -E '^[[:space:]]*_cx [0-9]+ codex exec' "$SKILL" | grep -c -- '-o "\$TMPRESP"' || true)
if [ "$execs" -ge 4 ] && [ "$execs" = "$with_o" ]; then ok "every codex exec writes its final message to \$TMPRESP"
else no "-o \$TMPRESP on $with_o of $execs codex exec calls"; fi
boundaries=$(grep -c 'IMPORTANT: Do NOT read or execute any files under' "$SKILL" || true)
skilled=$(grep 'IMPORTANT: Do NOT read or execute any files under' "$SKILL" | grep -c 'Do not invoke any installed skill' || true)
if [ "$boundaries" -ge 5 ] && [ "$boundaries" = "$skilled" ]; then ok "every boundary copy forbids invoking installed skills"
else no "do-not-invoke-skills sentence in $skilled of $boundaries boundary copies"; fi
if grep -q 'case "\$_SID" in '"''"'|\*\[!A-Za-z0-9._-\]\*)' "$SKILL"; then ok "resumed session id is validated"
else no "resumed session id reaches codex unvalidated"; fi
if grep -q 'checks 1, 2, 4' "$SKILL"; then no "unavailable label still names checks 1, 2, 4"
else ok "unavailable label names the right checks"; fi
if grep -q 'GATE: UNVERIFIED' "$SKILL"; then ok "gate has an UNVERIFIED state"
else no "gate has no UNVERIFIED state"; fi

# --- end to end: run blocks against a stub codex ------------------------------
# extract_block NEEDLE -> the bash fence in SKILL.md containing NEEDLE
extract_block() {
  python3 - "$SKILL" "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
needle, block, inside = sys.argv[2], [], False
for line in lines:
    if not inside and line.strip() == '```bash':
        inside, block = True, []
    elif inside and line.strip() == '```':
        inside = False
        if any(needle in b for b in block):
            print('\n'.join(block)); break
    elif inside:
        block.append(line)
PY
}

REPO="$TMP/repo"; mkdir -p "$REPO" "$TMP/bin"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$REPO/.vibestack/tmp"
cp "$VALIDATOR" "$REPO/.vibestack/tmp/codex-verdict.py"

# The stub writes $STUB_RESP to the -o file (or stdout for `codex review`),
# $STUB_EVENTS to stdout for exec, $STUB_ERR to stderr, and records its argv.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift ;; esac
  shift
done
cat >/dev/null
printf '%s' "${STUB_ERR:-}" >&2
if [ -n "$out" ]; then
  printf '%s' "${STUB_RESP:-}" > "$out"
  printf '%s\n' "${STUB_EVENTS:-}"
else
  printf '%s' "${STUB_RESP:-}"
fi
exit 0
STUB
chmod +x "$TMP/bin/codex"

run_block() { # NEEDLE PROMPT_TEXT -> stdout+stderr of the block
  local block name
  block=$(extract_block "$1")
  name="codex-prompt.test$RANDOM"
  printf '%s' "$2" > "$REPO/.vibestack/tmp/$name"
  block=${block//<prompt-file-name>/$name}
  block=${block//<new|resume>/new}
  (cd "$REPO" && PATH="$TMP/bin:$PATH" BASE=main TMP_ROOT="$TMP" STUB_ARGV="$TMP/argv" bash -c "$block" 2>&1) || true
}

echo "end to end"
CHALLENGE='codex exec - -C "$_REPO_ROOT" -s read-only -c '"'"'skills.include_instructions=false'"'"' -c '"'"'model_reasoning_effort="high"'
out=$(STUB_RESP='No problems found.' STUB_ERR='bwrap: Creating new namespace failed: Operation not permitted' \
  STUB_EVENTS="$BAD_CMD_PLAIN"$'\n{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}' \
  run_block "$CHALLENGE" 'challenge prompt')
if printf '%s' "$out" | grep -q 'CODEX_RESULT: FAILED (unavailable'; then ok "challenge: sandbox-failed run is FAILED, not OK"
else no "challenge: sandbox-failed run was not reported unavailable"; printf '%s\n' "$out" | sed 's/^/    /'; fi

out=$(STUB_RESP='Here is the attack surface: [P1] unbounded retry.' STUB_EVENTS="$OK_CMD"$'\n{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}' \
  run_block "$CHALLENGE" 'challenge prompt')
if printf '%s' "$out" | grep -q 'CODEX_RESULT: OK'; then ok "challenge: healthy run is OK"
else no "challenge: healthy run not OK"; printf '%s\n' "$out" | sed 's/^/    /'; fi
if grep -q 'skills.include_instructions=false' "$TMP/argv" && grep -q -- '-o ' "$TMP/argv"; then ok "challenge: argv carries the isolation flag and -o"
else no "challenge: argv missing isolation flag or -o"; fi

CONSULT='codex exec resume "$_SID"'
: > "$TMP/argv"
out=$(STUB_RESP='' STUB_EVENTS='{"type":"thread.started","thread_id":"t1"}'$'\n''{"type":"turn.completed","usage":{}}' \
  run_block "$CONSULT" 'a question')
if printf '%s' "$out" | grep -q 'CODEX_RESULT: FAILED (unavailable.*empty_response'; then ok "consult: empty final message is FAILED"
else no "consult: empty final message not reported unavailable"; printf '%s\n' "$out" | sed 's/^/    /'; fi

REVIEW='codex review --base "$BASE"'
out=$(STUB_RESP='I reviewed the diff and everything looks fine.' STUB_ERR=$'exec git diff\n succeeded in 9ms:' \
  run_block "$REVIEW" '')
if printf '%s' "$out" | grep -q '^VERDICT: unverified'; then ok "review: untagged clean-sounding prose is UNVERIFIED"
else no "review: untagged prose not graded unverified"; printf '%s\n' "$out" | sed 's/^/    /'; fi
out=$(STUB_RESP='No issues found.' STUB_ERR='Error: sandbox could not start (landlock not supported)' run_block "$REVIEW" '')
if printf '%s' "$out" | grep -q '^VERDICT: unavailable'; then ok "review: sandbox-not-started run is unavailable"
else no "review: sandbox-not-started run not unavailable"; printf '%s\n' "$out" | sed 's/^/    /'; fi
if ls "$REPO/.vibestack/tmp/" | grep -qE 'codex-resp|\.resp$|\.events$'; then no "response/event files left behind"
else ok "response and event files are removed"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
