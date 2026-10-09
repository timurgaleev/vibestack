#!/usr/bin/env bash
# test-health-scoring.sh — /health scores what the checkers actually reported.
#
# The bash blocks are pulled out of the rendered skill and executed:
#   - Step 2 capture: a checker exiting 1 reports EXIT:1 (never the status of a
#     display pipe), counts come from the full log rather than the shown tail, and
#     a command that cannot run reports its 127.
#   - Step 3 composite: computed in code; skipped categories redistribute weight
#     and are disclosed as partial coverage; zero checks and capture errors give
#     N/A, never a number.
# Then static checks on the step text: FAILED is not SKIPPED, no history row
# for an N/A run, and trends compare only identical coverage sets.
#
# Usage: test-health-scoring.sh [SKILL.md]   (default: skills/health/SKILL.md)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/skills/health/SKILL.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SKILL="$TMP/SKILL.md"
if ! "$ROOT/bin/vibe-render-skill" "$SRC" "$SKILL" >/dev/null 2>&1; then
  echo "cannot render $SRC" >&2; exit 1
fi

# block MARKER -> the first ```bash fence after the first line containing MARKER
block() {
  python3 -I - "$SKILL" "$1" <<'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
marker = sys.argv[2]
start = next((i for i, l in enumerate(text) if marker in l), None)
if start is None:
    sys.exit(1)
out, on = [], False
for line in text[start:]:
    if not on and line.strip() == "```bash":
        on = True
        continue
    if on and line.strip() == "```":
        break
    if on:
        out.append(line)
if not out:
    sys.exit(1)
print("\n".join(out))
PY
}

section() { awk -v a="$1" -v b="$2" 'index($0,a)==1 {on=1} on && index($0,b)==1 && index($0,a)!=1 {exit} on' "$SKILL"; }

echo "Step 1: detection"
if ! block "## Step 1: Detect Health Stack" > "$TMP/detect.sh"; then
  no "Step 1 detection block found"
else
  # A devDependency-only toolchain: the binaries exist only in node_modules/.bin.
  DP="$TMP/devdeps"
  mkdir -p "$DP/node_modules/.bin"
  : > "$DP/tsconfig.json"; : > "$DP/eslint.config.js"
  for t in tsc eslint; do printf '#!/usr/bin/env bash\necho ok\n' > "$DP/node_modules/.bin/$t"; chmod +x "$DP/node_modules/.bin/$t"; done
  out=$(cd "$DP" && PATH=/usr/bin:/bin bash "$TMP/detect.sh" 2>/dev/null)
  grep -qx 'TYPECHECK: ./node_modules/.bin/tsc --noEmit' <<<"$out" \
    && ok "local-only tsc is detected through node_modules/.bin" || no "local-only tsc detected bare: $out"
  grep -qx 'LINT: ./node_modules/.bin/eslint .' <<<"$out" \
    && ok "local-only eslint is detected through node_modules/.bin" || no "local-only eslint detected bare: $out"
  rm -rf "$DP/node_modules"
  out=$(cd "$DP" && PATH=/usr/bin:/bin bash "$TMP/detect.sh" 2>/dev/null)
  grep -qx 'TYPECHECK: tsc --noEmit' <<<"$out" \
    && ok "without node_modules the command stays bare" || no "bare detection changed: $out"
fi

echo "Step 2: capture"
if ! block "## Step 2: Run Tools" > "$TMP/capture.sh"; then
  no "Step 2 capture block found"
else
  grep -q 'tsc --noEmit' "$TMP/capture.sh" && ok "capture block runs the tool command" \
    || no "capture block lost its example command"

  # Fixture checkers stand in for tsc.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/fail-many" <<'SH'
#!/usr/bin/env bash
for i in $(seq 1 60); do echo "src/f$i.ts(1,1): error TS2322: bad"; done
exit 1
SH
  cat > "$TMP/bin/fail-silent" <<'SH'
#!/usr/bin/env bash
echo "something broke"
exit 1
SH
  cat > "$TMP/bin/pass-clean" <<'SH'
#!/usr/bin/env bash
echo "ok"
exit 0
SH
  chmod +x "$TMP/bin/"*

  run_capture() { # run_capture <command replacing tsc --noEmit>
    sed "s#tsc --noEmit#$1#" "$TMP/capture.sh" > "$TMP/run.sh"
    TMPDIR="$TMP" bash "$TMP/run.sh" 2>&1
  }

  out=$(run_capture "$TMP/bin/fail-many")
  line=$(grep '^TOOL:typecheck ' <<<"$out" | tail -1)
  grep -q ' EXIT:1 ' <<<"$line" && ok "failing checker reports EXIT:1" \
    || no "failing checker exit masked: $line"
  grep -q ' COUNT:60$' <<<"$line" && ok "count comes from the full log (60, not the 50-line tail)" \
    || no "count not from full log: $line"
  [ "$(grep -c 'error TS' <<<"$out")" -le 50 ] && ok "display is the last 50 lines" \
    || no "display not trimmed to 50 lines"

  out=$(run_capture "$TMP/bin/fail-silent")
  line=$(grep '^TOOL:typecheck ' <<<"$out" | tail -1)
  grep -q ' EXIT:1 ' <<<"$line" && grep -q ' COUNT:0$' <<<"$line" \
    && ok "non-zero exit with zero matches stays EXIT:1" || no "silent failure misreported: $line"

  out=$(run_capture "$TMP/bin/pass-clean")
  line=$(grep '^TOOL:typecheck ' <<<"$out" | tail -1)
  grep -q ' EXIT:0 ' <<<"$line" && ok "passing checker reports EXIT:0" || no "passing checker: $line"

  out=$(run_capture "$TMP/bin/no-such-checker")
  line=$(grep '^TOOL:typecheck ' <<<"$out" | tail -1)
  grep -q ' EXIT:127 ' <<<"$line" && ok "command that cannot run reports EXIT:127" \
    || no "missing command misreported: $line"

  [ -z "$(find "$TMP" -maxdepth 1 -name 'vibe-health.*' 2>/dev/null)" ] \
    && ok "capture log removed after the run" || no "capture log left behind"
fi

echo "Step 3: composite"
if ! block "**Composite score:**" > "$TMP/composite.sh"; then
  no "Step 3 composite block found"
else
  grep -q 'python3' "$TMP/composite.sh" && ok "composite computed in code" || no "composite not computed in code"
  # composite <args...> -> run the block's program with these category values
  composite() {
    python3 - "$TMP/composite.sh" "$@" <<'PY'
import re, subprocess, sys
src = open(sys.argv[1]).read()
m = re.search(r"python3 -I -c '(.*?)'", src, re.S)
if not m:
    sys.exit("no program in composite block")
r = subprocess.run(["python3", "-I", "-c", m.group(1)] + sys.argv[2:], capture_output=True, text=True)
sys.stdout.write(r.stdout + r.stderr)
sys.exit(r.returncode)
PY
  }
  out=$(composite typecheck=10 lint=10 test=10 deadcode=10 shell=10)
  grep -q '^COMPOSITE: 10.0$' <<<"$out" && grep -q '^COVERAGE: 5/5$' <<<"$out" \
    && ok "full coverage: 10.0, 5/5" || no "full coverage: $out"
  out=$(composite typecheck=10 lint=8 test=10 deadcode=8 shell=10)
  grep -q "^COMPOSITE: 9.3$" <<<"$out" && ok "weighted composite 9.3" || no "weighted composite: $out"
  out=$(composite typecheck=null lint=null test=4 deadcode=null shell=null)
  grep -q '^COMPOSITE: 4.0 (partial coverage)$' <<<"$out" && grep -q '^UNAVAILABLE: typecheck lint deadcode shell$' <<<"$out" \
    && ok "skipped weight redistributed and disclosed as partial coverage" || no "partial coverage: $out"
  out=$(composite typecheck=null lint=null test=null deadcode=null shell=null)
  grep -q '^COMPOSITE: N/A - no checks ran$' <<<"$out" && ! grep -q '^COMPOSITE: [0-9]' <<<"$out" \
    && ok "zero checks: N/A, no number" || no "zero checks: $out"
  out=$(composite typecheck=error lint=10 test=10 deadcode=10 shell=10)
  grep -q '^COMPOSITE: N/A - capture failed (typecheck)$' <<<"$out" \
    && ok "capture error: N/A, no redistribution" || no "capture error: $out"
  if composite typecheck=10 lint=10 test=10 deadcode=10 >/dev/null 2>&1; then
    no "missing category accepted"
  else
    ok "missing category rejected"
  fi
  if composite typecheck=11 lint=10 test=10 deadcode=10 shell=10 >/dev/null 2>&1; then
    no "out-of-range score accepted"
  else
    ok "out-of-range score rejected"
  fi
fi

echo "Static: step text"
s2=$(section "## Step 2: Run Tools" "## Step 3")
grep -q 'exit 126 or 127' <<<"$s2" && grep -q '\*\*FAILED\*\*' <<<"$s2" \
  && ok "a command that cannot run is FAILED" || no "exit 127 not FAILED"
s3=$(section "## Step 3" "## Step 4")
grep -q 'A non-zero exit is never `CLEAN` and never 10' <<<"$s3" \
  && ok "Step 3: a non-zero exit is never CLEAN" || no "Step 3 lost the non-zero-exit rule"
tr '\n' ' ' <<<"$s3" | grep -q 'Exit 126 or 127 is `FAILED` and scores 0' \
  && ok "Step 3: exit 126/127 scores 0, not the fallback 4" || no "Step 3 scores an unrunnable checker 4"
grep -q 'exit non-zero = 4' <<<"$s3" && no "Step 3 test fallback still covers 126/127" || ok "test fallback excludes 126/127"
grep -q '| tail -50' "$SKILL" && no "a pipe into tail is back in the skill" || ok "no checker piped into tail"
s5=$(section "## Step 5: Persist" "## Step 6")
grep -q 'Only when the composite is numeric' <<<"$s5" && ok "no history row for an N/A run" \
  || no "history written unconditionally"
s6=$(section "## Step 6: Trend" "## Important Rules")
grep -q 'Coverage changed — scores are' <<<"$s6" && grep -q "scored set equals this" <<<"$s6" \
  && ok "trends compare only identical coverage sets" || no "trend compares across coverage changes"
grep -q 'never show 10/10 for an empty run' "$SKILL" && ok "empty run never shows 10/10" || no "empty-run rule missing"
grep -q 'Skip only a tool whose absence was established before running' "$SKILL" \
  && ok "rule 4: skip only on established absence" || no "rule 4 still skips failures"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
