#!/usr/bin/env bash
# test-vibe-error-capture.sh — bin/vibe-error-capture runs a CLI's error path in
# isolation and reports only redacted output.
#
# /devex-review triggers a product's error paths (missing args, bad flags, bad
# input) to score its error messages. Those runs happen in the user's shell, so
# the wrapper is the boundary: nothing from the caller's environment reaches the
# command unless approved, the command cannot read stdin or write into the
# user's HOME or cwd, it cannot hang the audit, and a credential it prints never
# reaches the transcript.
#
# Value: protects=the isolation and redaction contract of the error-path runner;
# fails_when=an env var leaks through, HOME/cwd/stdin are the caller's, the
# timeout is ignored, --pass-env runs unapproved, or a key is echoed unmasked;
# why_new=the bin is new; seam=none (the real bin, real child processes)
#
# Usage: test/test-vibe-error-capture.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAP="$ROOT/bin/vibe-error-capture"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

[ -x "$CAP" ] || { no "bin/vibe-error-capture exists and is executable"; echo; echo "passed: $pass  failed: $fail"; exit 1; }

# field FILE EXPR — print a value from the captured JSON (EXPR indexes `r`).
field() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }

echo "isolation"
SENTINEL="hostile-$$-value"
OUT="$TMP/env.json"
HOSTILE_VAR="$SENTINEL" "$CAP" -- sh -c 'echo "[$HOSTILE_VAR]"; env' > "$OUT" 2>"$TMP/env.err"; rc=$?
[ "$rc" -eq 0 ] && ok "a captured run exits 0" || no "capture exit $rc: $(cat "$TMP/env.err")"
grep -qF "$SENTINEL" "$OUT" && no "a caller env var reached the command's output" \
  || ok "a caller env var never appears in the output"
[ "$(field "$OUT" 'r["exit_code"]')" = 0 ] && ok "the command's exit code is reported" \
  || no "exit_code: $(field "$OUT" 'r["exit_code"]')"
field "$OUT" 'r["stdout_head"]' | grep -q '^PATH=' && ok "PATH is passed through" || no "PATH missing from the child env"

"$CAP" -- sh -c 'printf "%s\n%s\n" "$HOME" "$(pwd -P)"' > "$TMP/dirs.json"
CHILD_HOME="$(field "$TMP/dirs.json" 'r["stdout_head"].splitlines()[0]')"
CHILD_CWD="$(field "$TMP/dirs.json" 'r["stdout_head"].splitlines()[1]')"
{ [ -n "$CHILD_HOME" ] && [ "$CHILD_HOME" != "$HOME" ] && [ "$CHILD_CWD" != "$(pwd -P)" ]; } \
  && ok "HOME and cwd are fresh directories" || no "HOME=$CHILD_HOME cwd=$CHILD_CWD"
{ [ ! -e "$CHILD_HOME" ] && [ ! -e "$CHILD_CWD" ]; } \
  && ok "the scratch HOME and cwd are removed afterwards" || no "scratch dirs left behind"

echo "piped input" | "$CAP" -- cat > "$TMP/stdin.json"
[ "$(field "$TMP/stdin.json" 'repr(r["stdout_head"])')" = "''" ] \
  && ok "stdin is /dev/null, not the caller's input" || no "stdin leaked: $(field "$TMP/stdin.json" 'r["stdout_head"]')"

echo "timeout"
start=$(date +%s)
"$CAP" --timeout 1 -- sh -c 'sleep 30' > "$TMP/slow.json"; rc=$?
elapsed=$(( $(date +%s) - start ))
{ [ "$rc" -eq 0 ] && [ "$elapsed" -lt 10 ]; } && ok "the timeout stops a hung command (${elapsed}s)" \
  || no "timeout ignored: rc=$rc elapsed=${elapsed}s"
[ "$(field "$TMP/slow.json" 'r["timed_out"]')" = True ] && [ "$(field "$TMP/slow.json" 'r["exit_code"]')" = None ] \
  && ok "a timed-out run reports timed_out and no exit code" || no "timeout fields: $(cat "$TMP/slow.json")"

# Value: protects=a timed-out run leaves nothing running; fails_when=a grandchild that called setsid outlives the process-group kill; why_new=the row above only kills a same-group child; seam=none (a real double-forked child)
ESC="$TMP/escaped.pid"
"$CAP" --timeout 1 -- python3 -c '
import os, sys, time
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        open(sys.argv[1], "w").write(str(os.getpid()))
        os.execvp("sleep", ["sleep", "60"])
    os._exit(0)
time.sleep(60)' "$ESC" > "$TMP/esc.json" 2>&1
sleep 1
epid="$(cat "$ESC" 2>/dev/null)"
if [ -z "$epid" ]; then
  no "escaped grandchild never started: $(cat "$TMP/esc.json")"
elif kill -0 "$epid" 2>/dev/null; then
  kill -KILL "$epid" 2>/dev/null
  no "a setsid grandchild (pid $epid) survived the timeout"
else
  ok "a setsid grandchild in the scratch cwd is killed on timeout"
fi

echo "approval"
"$CAP" --pass-env HOSTILE_VAR -- sh -c "touch '$TMP/ran'" > "$TMP/unapproved.json" 2>"$TMP/unapproved.err"; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -e "$TMP/ran" ]; } && ok "--pass-env without --approved is refused before running" \
  || no "unapproved --pass-env: rc=$rc ran=$([ -e "$TMP/ran" ] && echo yes || echo no)"
HOSTILE_VAR="$SENTINEL" "$CAP" --approved --pass-env HOSTILE_VAR -- sh -c 'echo "[$HOSTILE_VAR]"' > "$TMP/approved.json"
grep -qF "[$SENTINEL]" "$TMP/approved.json" && ok "an approved --pass-env name reaches the command" \
  || no "approved pass-env missing: $(cat "$TMP/approved.json")"

echo "error output"
"$CAP" -- sh -c 'echo "error: missing <file>" >&2; exit 3' > "$TMP/err.json"
{ [ "$(field "$TMP/err.json" 'r["exit_code"]')" = 3 ] \
  && [ "$(field "$TMP/err.json" 'r["stderr_head"].strip()')" = "error: missing <file>" ]; } \
  && ok "stderr and a non-zero exit are captured" || no "error capture: $(cat "$TMP/err.json")"
# Built at run time so no key-shaped literal sits in the tree.
FAKE_AKID="AKIA$(printf 'Q7%.0s' 1 2 3 4 5 6 7 8)"
"$CAP" -- sh -c "echo 'auth failed for $FAKE_AKID' >&2; exit 1" > "$TMP/secret.json"
grep -qF "$FAKE_AKID" "$TMP/secret.json" && no "a credential in stderr reached the output" \
  || ok "a credential in stderr is masked"
[ "$(field "$TMP/secret.json" '[(f["stream"], f["label"]) for f in r["secret_findings"]]')" = "[('stderr', 'AWS access key')]" ] \
  && ok "secret_findings names the stream and pattern" || no "secret_findings: $(field "$TMP/secret.json" 'r["secret_findings"]')"
"$CAP" --head 10 -- sh -c 'printf "%0100d" 0' > "$TMP/long.json"
{ [ "$(field "$TMP/long.json" 'len(r["stdout_head"])')" -le 10 ] && [ "$(field "$TMP/long.json" 'r["stdout_truncated"]')" = True ]; } \
  && ok "output is cut to --head bytes and marked truncated" || no "head: $(cat "$TMP/long.json")"
# A flood of output must not be held in memory: only the first 64 KiB is kept.
PEAK="$(python3 -I -c '
import resource, subprocess, sys
out = subprocess.run([sys.argv[1], "--", "sh", "-c", "head -c 300000000 /dev/zero; echo done >&2"],
                     stdout=subprocess.PIPE).stdout
r = __import__("json").loads(out)
kb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
kb = kb // 1024 if sys.platform == "darwin" else kb
print(kb if r["stdout_truncated"] and r["stderr_head"].strip() == "done" else -1)' "$CAP" 2>&1)"
{ [ "$PEAK" -ge 0 ] 2>/dev/null && [ "$PEAK" -lt 150000 ]; } \
  && ok "a 300 MB flood is capped, not buffered (peak ${PEAK} KiB)" || no "flood: peak/result $PEAK"
"$CAP" -- no-such-command-$$ > "$TMP/missing.json"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(field "$TMP/missing.json" 'r["exit_code"]')" = 127 ]; } \
  && ok "a missing command reports exit_code 127" || no "missing command: rc=$rc $(cat "$TMP/missing.json")"
"$CAP" > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no command is a usage error" || no "no command exit $rc"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
