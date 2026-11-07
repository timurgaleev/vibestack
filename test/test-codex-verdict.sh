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
fixed=$(grep -E '^[[:space:]]*_cx [0-9]+ codex (review|exec)' "$SKILL" | grep -cE 'model_reasoning_effort="(high|medium|low|xhigh)"' || true)
if [ "$calls" -ge 5 ] && [ "$fixed" = 0 ]; then ok "no codex call hardcodes its reasoning effort"
else no "$fixed codex calls still hardcode model_reasoning_effort"; fi
if grep -q -- '--effort <low|medium|high|xhigh>' "$SKILL" && grep -q 'VIBE_CODEX_EFFORT' "$SKILL"; then ok "Step 1 documents --effort and VIBE_CODEX_EFFORT"
else no "Step 1 does not document --effort / VIBE_CODEX_EFFORT"; fi
S05=$(awk '/^## Step 0.5:/{on=1;next} on&&/^## /{exit} on' "$SKILL")
for v in model_unusable sandbox_unavailable; do
  if printf '%s' "$S05" | grep -q "\*\*\`$v\`\*\*"; then ok "Step 0.5 branches on $v"
  else no "Step 0.5 has no $v branch"; fi
done
if printf '%s' "$S05" | grep -q -- '--model'; then ok "Step 0.5 passes a requested model to the probe"
else no "Step 0.5 never passes the model to the probe"; fi

# --- vibe-codex-probe against a stub codex ------------------------------------
echo "probe"
PROBE="$ROOT/bin/vibe-codex-probe"
PB="$TMP/pbin"; mkdir -p "$PB" "$TMP/cxhome"
: > "$TMP/cxhome/auth.json"; printf 'model = "gpt-x"\n' > "$TMP/cxhome/config.toml"
# One argument per [..] so a value with spaces or quotes is checked exactly.
cat > "$PB/codex" <<'STUB'
#!/usr/bin/env bash
printf '[%s]' "$@" >> "$PSTUB_ARGV"; echo >> "$PSTUB_ARGV"
if [ "$1" = sandbox ]; then
  [ -n "${PSTUB_SANDBOX_ERR:-}" ] && { printf '%s\n' "$PSTUB_SANDBOX_ERR" >&2; exit 1; }
  exit 0
fi
[ -n "${PSTUB_ERR:-}" ] && { printf '%s\n' "$PSTUB_ERR" >&2; exit 1; }
echo OK
STUB
printf '#!/bin/sh\necho "${PSTUB_OS:-Darwin}"\n' > "$PB/uname"
chmod +x "$PB/codex" "$PB/uname"
probe() { # STATE_DIR ARGS... -> probe stdout+stderr
  local h=$1; shift
  env -u CODEX_API_KEY -u OPENAI_API_KEY PATH="$PB:$PATH" CODEX_HOME="$TMP/cxhome" \
    VIBESTACK_HOME="$h" PSTUB_ARGV="$TMP/pargv" bash "$PROBE" "$@" 2>&1 || return $?
}
pfirst() { printf '%s\n' "$1" | head -1; }

: > "$TMP/pargv"
out=$(probe "$TMP/ph1") || true
expect "a healthy round trip is usable" "CODEX: usable" "$(pfirst "$out")"
if grep -q '\[skills.include_instructions=false\]' "$TMP/pargv"; then ok "the probe keeps installed skills out of its round trip"
else no "the probe round trip loads installed skills"; fi
if grep -q '^\[sandbox\]' "$TMP/pargv"; then no "the sandbox rung ran off Linux"; else ok "the sandbox rung is Linux-only"; fi

: > "$TMP/pargv"
out=$(probe "$TMP/ph2" --model gpt-5.2-codex) || true
if grep -q '\[-c\]\[model="gpt-5.2-codex"\]' "$TMP/pargv"; then ok "--model reaches the probe as -c model=\"<m>\""
else no "--model not passed to the probe round trip"; sed 's/^/    /' "$TMP/pargv"; fi
rc=0; out=$(probe "$TMP/ph2" --model 'bad"model') || rc=$?
[ "$rc" = 2 ] && ok "a model name outside [A-Za-z0-9._:/-] is a usage error" || no "unsafe model name accepted (rc $rc)"

for msg in \
  'ERROR: {"detail":"The '"'"'gpt-9'"'"' model is not supported when using Codex with a ChatGPT account.","status":400}' \
  'unexpected status 404 Not Found: The model `gpt-9` does not exist or you do not have access to it.' \
  'Error: the gpt-9 model requires a newer version of Codex; upgrade the CLI.'; do
  out=$(PSTUB_ERR="$msg" probe "$TMP/ph3" --refresh) || true
  expect "model error -> model_unusable (${msg:0:40}...)" "CODEX: model_unusable" "$(pfirst "$out")"
done
if printf '%s\n' "$out" | grep -q '^DETAIL: .*newer version'; then ok "model_unusable relays the CLI's message as DETAIL"
else no "model_unusable carries no DETAIL"; fi
out=$(PSTUB_ERR='' probe "$TMP/ph3") || true
if [ "$(pfirst "$out")" = "CODEX: model_unusable" ] && printf '%s\n' "$out" | grep -q '^DETAIL: '; then ok "a cached model_unusable still prints its DETAIL"
else no "cached model_unusable lost its verdict or DETAIL: $out"; fi
# Status codes and "not supported" also appear in failures that have nothing to
# do with the model; those must not be reported as a refused model.
out=$(PSTUB_ERR='unexpected status 401 Unauthorized: this token is not supported' probe "$TMP/ph3" --refresh) || true
expect "a 401 that says 'not supported' is still unauthenticated" "CODEX: unauthenticated" "$(pfirst "$out")"
out=$(PSTUB_ERR='stream error: status 400 Bad Request: context_length_exceeded' probe "$TMP/ph3" --refresh) || true
expect "a bare 'status 400' is not a refused model" "CODEX: error" "$(pfirst "$out")"
# A flag with its value missing is a usage error, not an endless loop.
for flag in --model --ttl; do
  # The probe itself is the background job, so the kill reaches it, not a subshell.
  VIBESTACK_HOME="$TMP/ph3" PATH="$PB:$PATH" bash "$PROBE" "$flag" >/dev/null 2>&1 & ppid=$!
  w=0; while kill -0 "$ppid" 2>/dev/null && [ "$w" -lt 50 ]; do sleep 0.1; w=$((w+1)); done
  rc=0
  if kill -0 "$ppid" 2>/dev/null; then kill -KILL "$ppid" 2>/dev/null; wait "$ppid" 2>/dev/null || true; no "$flag with no value hangs the probe"
  else wait "$ppid" || rc=$?; [ "$rc" = 2 ] && ok "$flag with no value is a usage error" || no "$flag with no value exits $rc"; fi
done

# The cache key has to move with everything the verdict depends on.
probe "$TMP/ph4" >/dev/null || true
out=$(PSTUB_ERR='boom' probe "$TMP/ph4") || true
expect "an unchanged context reuses the cached verdict" "CODEX: usable" "$(pfirst "$out")"
touch -t 202001010000 "$TMP/cxhome/config.toml"
out=$(PSTUB_ERR='boom' probe "$TMP/ph4") || true
expect "editing config.toml invalidates a cached usable" "CODEX: error" "$(pfirst "$out")"
probe "$TMP/ph5" >/dev/null || true
touch -t 202001010000 "$PB/codex"
out=$(PSTUB_ERR='boom' probe "$TMP/ph5") || true
expect "replacing the codex binary invalidates a cached usable" "CODEX: error" "$(pfirst "$out")"
probe "$TMP/ph6" >/dev/null || true
out=$(PSTUB_ERR='boom' probe "$TMP/ph6" --model other-model) || true
expect "a different --model is a different verdict" "CODEX: error" "$(pfirst "$out")"

: > "$TMP/pargv"
out=$(PSTUB_OS=Linux PSTUB_SANDBOX_ERR='bwrap: No permissions to create new namespace' probe "$TMP/ph7") || true
expect "Linux: a sandbox that cannot start -> sandbox_unavailable" "CODEX: sandbox_unavailable" "$(pfirst "$out")"
if printf '%s\n' "$out" | grep -q '^DETAIL: bwrap' && printf '%s\n' "$out" | grep -qi '^DETAIL: .*namespace'; then ok "sandbox_unavailable relays the failure and a fix hint"
else no "sandbox_unavailable without DETAIL/hint: $out"; fi
if grep -q '^\[exec\]' "$TMP/pargv"; then no "the paid round trip ran after the sandbox failed"; else ok "no paid round trip after a sandbox failure"; fi
: > "$TMP/pargv"
out=$(PSTUB_OS=Linux probe "$TMP/ph8") || true
expect "Linux: a working sandbox continues to the round trip" "CODEX: usable" "$(pfirst "$out")"
if grep -q '^\[sandbox\]\[-c\]\[sandbox_mode="read-only"\]\[true\]' "$TMP/pargv"; then ok "the sandbox rung runs codex sandbox read-only true"
else no "sandbox rung argv wrong"; sed 's/^/    /' "$TMP/pargv"; fi
# A CLI that predates this sandbox form rejects the command line itself; the
# fix is an upgrade, not a sysctl, and the hint must say so.
out=$(PSTUB_OS=Linux PSTUB_SANDBOX_ERR="error: unrecognized subcommand 'true'" probe "$TMP/ph9") || true
expect "Linux: a CLI that rejects the sandbox command -> sandbox_unavailable" "CODEX: sandbox_unavailable" "$(pfirst "$out")"
if printf '%s\n' "$out" | grep -qi '^DETAIL: .*upgrade' && ! printf '%s\n' "$out" | grep -qi 'namespace'; then ok "a rejected sandbox command hints an upgrade, not user namespaces"
else no "rejected sandbox command gets the wrong hint: $out"; fi

# Step 0.5's own block hands the model to the probe as two arguments, in bash
# and in zsh (which does not word-split an unquoted ${x:+...}). printf "[%s]"
# with no arguments prints "[]".
S05B=$(awk '/^```bash$/{f=1;b="";next} f&&/^```$/{f=0; if(b ~ /_MODEL=/){printf "%s", b; exit} next} f{b=b $0 "\n"}' "$SKILL")
mkdir -p "$TMP/vh/bin"
printf '#!/bin/sh\nprintf "[%%s]" "$@" > "%s"\necho "CODEX: usable"\n' "$TMP/probe-args" > "$TMP/vh/bin/vibe-codex-probe"
chmod +x "$TMP/vh/bin/vibe-codex-probe"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { ok "SKIP $sh not installed"; continue; }
  : > "$TMP/probe-args"
  VIBESTACK_HOME="$TMP/vh" "$sh" -c "${S05B//<MODEL>/gpt-5.2-codex}" >/dev/null 2>&1 || true
  expect "Step 0.5 under $sh passes --model as its own argument" "[--model][gpt-5.2-codex]" "$(cat "$TMP/probe-args")"
  : > "$TMP/probe-args"
  VIBESTACK_HOME="$TMP/vh" "$sh" -c "${S05B//<MODEL>/}" >/dev/null 2>&1 || true
  expect "Step 0.5 under $sh with no model passes nothing" "[]" "$(cat "$TMP/probe-args")"
done

# --- date grounding snippet ---------------------------------------------------
echo "grounding"
GSNIP="$ROOT/lib/snippets/second-opinion-grounding.md"
if [ -f "$GSNIP" ]; then
  awk '/^```bash$/{f=1;next} /^```$/{if(f)exit} f' "$GSNIP" > "$TMP/ground.sh"
  printf 'the question\n' > "$TMP/gprompt"
  sed -i.bak "s|<prompt-file-path>|$TMP/gprompt|g" "$TMP/ground.sh"
  gout=$(bash "$TMP/ground.sh" 2>&1)
  today=$(date -u +%F)
  if grep -qxF "Current date (UTC): $today" "$TMP/gprompt" && printf '%s' "$gout" | grep -qF "Current date (UTC): $today"; then ok "the block prints the UTC date and writes it into the prompt file"
  else no "date line missing from the prompt file or the output"; fi
  if grep -q '\[unverified\]' "$TMP/gprompt" && head -1 "$TMP/gprompt" | grep -qx 'the question'; then ok "the unrecognised-name rule is appended after the prompt"
  else no "the [unverified] rule is missing, or the prompt was overwritten"; fi
else
  no "lib/snippets/second-opinion-grounding.md missing"
fi
for step in '## Step 2B:' '## Step 2C:'; do
  sec=$(awk -v a="$step" 'index($0,a)==1{on=1;next} on&&/^## /{exit} on' "$SKILL")
  if printf '%s' "$sec" | grep -q 'Date Grounding'; then ok "${step#\#\# } runs the date grounding on its prompt file"
  else no "${step#\#\# } does not run the date grounding"; fi
done
if grep -qx '{{include lib/snippets/second-opinion-grounding.md}}' "$SKILL"; then ok "the skill includes the grounding snippet"
else no "the skill does not include the grounding snippet"; fi

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
cat > "${STUB_STDIN:-/dev/null}"
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
  block=${block//<focus-file-name>/$name}
  block=${block//<new|resume>/new}
  block=${block//<BASE>/main}
  block=${block//<EFFORT>/${EFFORT_SUB:-}}
  block=${block//<TMPERR>/$(mktemp "$TMP/codex-err-XXXXXX")}
  (cd "$REPO" && env -u BASE -u TMPERR -u TMP_ROOT -u VIBE_CODEX_EFFORT ${CX_EFFORT_ENV:+VIBE_CODEX_EFFORT="$CX_EFFORT_ENV"} PATH="$TMP/bin:$PATH" STUB_ARGV="$TMP/argv" bash -c "$block" 2>&1) || true
}

echo "end to end"
CHALLENGE='{"skill":"codex-challenge"'
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

# Reasoning effort: the --effort request wins, then VIBE_CODEX_EFFORT, then the
# mode default; anything outside low|medium|high|xhigh stops before Codex runs.
effort_of() { sed -n 's/.*model_reasoning_effort="\([^"]*\)".*/\1/p' "$TMP/argv" | tail -1; }
OKRUN_EVENTS="$OK_CMD"$'\n{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
: > "$TMP/argv"; STUB_RESP='An answer.' STUB_EVENTS="$OKRUN_EVENTS" run_block "$CHALLENGE" 'p' >/dev/null
expect "challenge: no request and no env -> high" high "$(effort_of)"
: > "$TMP/argv"; CX_EFFORT_ENV=low STUB_RESP='An answer.' STUB_EVENTS="$OKRUN_EVENTS" run_block "$CHALLENGE" 'p' >/dev/null
expect "challenge: VIBE_CODEX_EFFORT=low -> low" low "$(effort_of)"
: > "$TMP/argv"; EFFORT_SUB=xhigh CX_EFFORT_ENV=low STUB_RESP='An answer.' STUB_EVENTS="$OKRUN_EVENTS" run_block "$CHALLENGE" 'p' >/dev/null
expect "challenge: the --effort request beats the env" xhigh "$(effort_of)"
: > "$TMP/argv"; out=$(CX_EFFORT_ENV=turbo STUB_RESP='An answer.' STUB_EVENTS="$OKRUN_EVENTS" run_block "$CHALLENGE" 'p')
if printf '%s' "$out" | grep -q 'Not run' && [ ! -s "$TMP/argv" ]; then ok "challenge: an invalid effort stops before Codex runs"
else no "challenge: invalid effort reached Codex"; printf '%s\n' "$out" | sed 's/^/    /'; fi
: > "$TMP/argv"; STUB_RESP='An answer.' STUB_EVENTS="$OKRUN_EVENTS" run_block 'codex exec resume "$_SID"' 'q' >/dev/null
expect "consult: default effort is medium" medium "$(effort_of)"
: > "$TMP/argv"; CX_EFFORT_ENV=low STUB_RESP='[P2] x' run_block 'codex review --base "$BASE"' '' >/dev/null
expect "review: VIBE_CODEX_EFFORT reaches the bare review call" low "$(effort_of)"

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

# Custom-instructions path: the diff is built locally, so a base that does not
# resolve or an empty diff must make the review unavailable before Codex runs.
# An empty DIFF_START/DIFF_END block let Codex answer NO_FINDINGS -> clean -> PASS.
CUSTOM='codex exec - -s read-only'
git -C "$REPO" branch -M trunk
: > "$TMP/argv"
out=$(STUB_RESP=$'Nothing to review.\nNO_FINDINGS' run_block "$CUSTOM" 'focus on auth')
if printf '%s' "$out" | grep -q '^VERDICT: unavailable' && [ ! -s "$TMP/argv" ]; then ok "custom review: unresolvable base is unavailable, Codex not run"
else no "custom review: unresolvable base not reported unavailable"; printf '%s\n' "$out" | sed 's/^/    /'; fi
git -C "$REPO" branch main
: > "$TMP/argv"
out=$(STUB_RESP=$'Nothing to review.\nNO_FINDINGS' run_block "$CUSTOM" 'focus on auth')
if printf '%s' "$out" | grep -q '^VERDICT: unavailable' && [ ! -s "$TMP/argv" ]; then ok "custom review: empty diff is unavailable, Codex not run"
else no "custom review: empty diff not reported unavailable"; printf '%s\n' "$out" | sed 's/^/    /'; fi
echo change > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m change
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse main)"
git -C "$REPO" branch -D -q main
out=$(STUB_RESP=$'NO_FINDINGS' run_block "$CUSTOM" 'focus on auth')
if printf '%s' "$out" | grep -q '^VERDICT: clean' && [ -s "$TMP/argv" ]; then ok "custom review: diff against origin/<base> reaches Codex"
else no "custom review: diff against origin/<base> did not reach Codex"; printf '%s\n' "$out" | sed 's/^/    /'; fi
# Uncommitted edits to tracked files are part of what gets reviewed: the diff
# runs from the merge base to the working tree, not to HEAD.
echo dirty-edit-marker >> "$REPO/f.txt"
out=$(STUB_STDIN="$TMP/stdin" STUB_RESP=$'NO_FINDINGS' run_block "$CUSTOM" 'focus on auth')
if grep -q 'dirty-edit-marker' "$TMP/stdin" 2>/dev/null; then ok "custom review: an uncommitted edit reaches the Codex prompt"
else no "custom review: the uncommitted edit was left out of the diff"; fi
git -C "$REPO" checkout -q -- f.txt

# --- /review Step 4.8 and /ship Step 11: probe-backed mode, graded adversarial pass ---
# block_in FILE NEEDLE -> the bash fence in FILE containing NEEDLE, <base> -> main
block_in() {
  python3 -I - "$1" "$2" <<'PY' | sed 's/<base>/main/g'
import sys
needle, block, inside = sys.argv[2], [], False
for line in open(sys.argv[1]).read().split('\n'):
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
VH="$TMP/vh"; mkdir -p "$VH/bin"
mode_of() { # FILE PROBE_LINE|missing [ENV...] -> the CODEX_MODE the block resolves
  local f="$1" probe="$2"; shift 2
  rm -f "$VH/bin/vibe-codex-probe"
  if [ "$probe" != missing ]; then
    printf '#!/usr/bin/env bash\necho "%s"\n' "$probe" > "$VH/bin/vibe-codex-probe"; chmod +x "$VH/bin/vibe-codex-probe"
  fi
  (cd "$REPO" && env -u CODEX_THREAD_ID -u CODEX_SANDBOX -u VIBE_FORCE_CODEX_REVIEW -u CODEX_API_KEY -u OPENAI_API_KEY \
    CODEX_HOME="$TMP/codex-home" VIBESTACK_HOME="$VH" PATH="$TMP/bin:$PATH" "$@" \
    bash -c "$(block_in "$f" 'echo "CODEX_MODE: $CODEX_MODE"')" 2>&1 | sed -n 's/^CODEX_MODE: //p') || true
}
# grade_of FILE RESPONSE -> the block's ADVERSARIAL: line
grade_of() {
  (cd "$REPO" && env -u CODEX_THREAD_ID -u CODEX_SANDBOX STUB_RESP="$2" STUB_EVENTS='' STUB_ARGV="$TMP/argv" \
    PATH="$TMP/bin:$PATH" bash -c "$(block_in "$1" 'codex exec "IMPORTANT: Do NOT read')" 2>&1 | sed -n 's/^ADVERSARIAL: //p') || true
}
mkdir -p "$TMP/codex-home"; printf '{}\n' > "$TMP/codex-home/auth.json"
for f in "$ROOT/skills/review/SKILL.md" "$ROOT/skills/ship/SKILL.md"; do
  n=$(basename "$(dirname "$f")")
  echo "$n: Codex mode comes from the probe"
  expect "$n: probe usable -> ready" ready "$(mode_of "$f" 'CODEX: usable')"
  expect "$n: probe unauthenticated -> not_authed" not_authed "$(mode_of "$f" 'CODEX: unauthenticated')"
  expect "$n: probe quota_exhausted -> quota_exhausted" quota_exhausted "$(mode_of "$f" 'CODEX: quota_exhausted')"
  expect "$n: auth.json present but no probe -> unavailable" unavailable "$(mode_of "$f" missing)"
  expect "$n: under a Codex host -> under_codex" under_codex "$(mode_of "$f" 'CODEX: usable' CODEX_THREAD_ID=t1)"
  echo "$n: the Codex adversarial reply is graded"
  got="$(grade_of "$f" $'The retry loop never stops on a 500.\nIt also leaks the handle.')"
  expect "$n: no closing Recommendation line -> missing coverage" MISSING_COVERAGE "${got%% *}"
  got="$(grade_of "$f" $'[P1] (confidence: 8/10) a.rb:3 — unbounded retry\nRecommendation: FIX FIRST — the retry storms the API')"
  expect "$n: tagged findings + Recommendation -> covered" COVERED "${got%% *}"
  got="$(grade_of "$f" $'Checked the parser and the auth path.\nRecommendation: SHIP — nothing reachable fails')"
  expect "$n: clean reply with the marker -> covered" COVERED "${got%% *}"
  got="$(grade_of "$f" $'The retry loop never stops.\nRecommendation: FIX FIRST — retries storm')"
  expect "$n: findings without severity -> missing coverage" MISSING_COVERAGE "${got%% *}"
  got="$(grade_of "$f" $'Recommendation: SHIP — fine\nActually, wait: [P1] a.rb:3 leaks')"
  expect "$n: text after the Recommendation line -> missing coverage" MISSING_COVERAGE "${got%% *}"
  got="$(grade_of "$f" $'1. [P1] a.rb:3 — unbounded retry\n2. **[P2]** b.rb:9 — leaked handle\nRecommendation: FIX FIRST — the retry storms the API')"
  expect "$n: numbered-list findings + Recommendation -> covered" COVERED "${got%% *}"
  got="$(grade_of "$f" $'| Severity | Finding |\n|---|---|\n| [P1] | a.rb:3 unbounded retry |\nRecommendation: FIX FIRST — the retry storms the API')"
  expect "$n: table-row findings + Recommendation -> covered" COVERED "${got%% *}"
  got="$(grade_of "$f" $'1. The retry loop never stops (see P1 above).\n| a.rb:3 | retry |\nRecommendation: FIX FIRST — retries storm')"
  expect "$n: numbered and table text without a tag -> missing coverage" MISSING_COVERAGE "${got%% *}"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
