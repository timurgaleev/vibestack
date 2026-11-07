#!/usr/bin/env bash
# vibe-redact scan: deterministic, fail-closed credential scan over files, sharing
# its matcher with the pre-push guard. Credentials are assembled at runtime so
# this file never carries a live-shaped token itself.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
export VIBESTACK_HOME="$TMP/home"
mkdir -p "$VIBESTACK_HOME"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
no()   { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

AWS_KEY="AKIA""QWERTYUIOPASDFGH"
AWS_DOC_KEY="AKIA""IOSFODNN7EXAMPLE"
PEM_HEAD="-----BEGIN RSA ""PRIVATE KEY-----"
GH_TOKEN="ghp_""$(printf 'aB3%.0s' $(seq 1 12))"
BEARER="Bearer ""eyJhbGciOiJIUzI1NiJ9xQ7Lm2Pz"

scan() { "$BIN/vibe-redact" scan "$@"; }

# 1. AWS key -> exit 1, finding names pattern, path and line, and is masked.
f="$TMP/aws.md"; printf 'intro\nkey = %s\n' "$AWS_KEY" > "$f"
out=$(scan --file "$f" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "AWS key exits 1" || no "AWS key exit=$rc"
echo "$out" | grep -q "AWS access key" && echo "$out" | grep -q "$f:2" \
  && ok "finding names pattern and path:line" || no "finding format: $out"
echo "$out" | grep -qF "$AWS_KEY" && no "full key echoed unmasked" || ok "key masked in output"

# 2. Clean file -> exit 0 with the clean marker.
f="$TMP/clean.md"; printf '# Title\nUse sk-learning-rate wisely.\nBearer YOUR_TOKEN_HERE\n' > "$f"
out=$(scan --file "$f" 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q '^REDACT_SCAN: clean' && ok "clean file passes" || no "clean file rc=$rc out=$out"

# 3. Fail closed: missing file, no args, unknown arg -> exit 2.
scan --file "$TMP/nope.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing file exits 2" || no "missing file exit=$rc"
scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no --file exits 2" || no "no --file exit=$rc"
scan --bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unknown arg exits 2" || no "unknown arg exit=$rc"
scan --file >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "--file without a path exits 2" || no "--file without path exit=$rc"

# 4. Matcher missing -> exit 2, never a silent clean.
mkdir -p "$TMP/lonely"; cp "$BIN/vibe-redact" "$TMP/lonely/"
"$TMP/lonely/vibe-redact" scan --file "$TMP/clean.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing matcher exits 2" || no "missing matcher exit=$rc"

# 5. Private key block is detected (the pattern starts with '-').
f="$TMP/pem.md"; printf '%s\nMIIabc\n' "$PEM_HEAD" > "$f"
scan --file "$f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "private key block blocks" || no "private key block exit=$rc"

# 6. Documentation placeholders pass; a live value next to the word example does not.
f="$TMP/doc.md"
printf 'aws_access_key_id = %s\nAPI_KEY=your-api-key\nDB_PASSWORD=<password>\nAPI_TOKEN=xxxxxxxx\n' "$AWS_DOC_KEY" > "$f"
scan --file "$f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "doc placeholders pass" || no "doc placeholders exit=$rc"
f="$TMP/doc2.md"; printf 'Example:\nEXAMPLE_API_KEY=s3cr3tValue99\n' > "$f"
scan --file "$f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "live env value under an example name blocks" || no "env example-name exit=$rc"
f="$TMP/doc3.md"; printf 'AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCY%s\n' "EXAMPLEKEY" > "$f"
scan --file "$f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "the documented AWS example secret passes" || no "AWS doc secret exit=$rc"
f="$TMP/doc4.md"; printf 'DB_PASSWORD=MyExample%s\n' "Corp2024!" > "$f"
scan --file "$f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "a live value with example in the middle blocks" || no "mid-word example exit=$rc"

# 7. Other shapes: GitHub token, high-entropy bearer.
f="$TMP/gh.md"; printf 'token: %s\n' "$GH_TOKEN" > "$f"
scan --file "$f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "GitHub token blocks" || no "GitHub token exit=$rc"
f="$TMP/bearer.md"; printf 'Authorization: %s\n' "$BEARER" > "$f"
scan --file "$f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "high-entropy bearer blocks" || no "bearer exit=$rc"

# 7b. Credential shapes the list once missed: GitHub user-to-server, refresh
#     and fine-grained tokens, Slack, Stripe live keys, Google API keys. Each
#     blocks the scan, the pre-push list carries it, and the shared snippet
#     documents it so the two copies cannot drift apart.
B36="$(printf 'aB3%.0s' $(seq 1 12))"
for tok in "ghu_$B36" "ghr_$B36" "github_pat_""11ABCDEFG0123456789_abcdefghijklmnop" \
           "xoxb-""1234567890-abcdefABCDEF" "sk_live_""Zx81Qw7Lm2Pz0Rt5Yu9Io3Kj" \
           "rk_live_""Zx81Qw7Lm2Pz0Rt5Yu9Io3Kj" "AIza""SyD0123456789abcdefghijklmnopqrstuv"; do
  f="$TMP/shape.md"; printf 'value: %s\n' "$tok" > "$f"
  scan --file "$f" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "${tok:0:5}... credential blocks" || no "${tok:0:5}... credential exit=$rc"
done
for pat in 'gh(p|o|s|u|r)_' 'github_pat_' 'xox[abpr]-' '(sk|rk)_live_' 'AIza[0-9A-Za-z_-]{35}'; do
  grep -qF -- "$pat" "$BIN/vibe-redact-prepush" && grep -qF -- "$pat" "$ROOT/lib/snippets/secret-scan-patterns.md" \
    && ok "pattern $pat is in the pre-push list and the snippet" || no "pattern $pat missing from the list or the snippet"
done

# 8. Several files: the dirty one is named, exit 1; spaces in a path are fine.
f="$TMP/with space.md"; printf 'x\ny\n%s\n' "$AWS_KEY" > "$f"
out=$(scan --file "$TMP/clean.md" --file "$f" 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -qF "$f:3" && ok "multi-file names the dirty file" || no "multi-file rc=$rc out=$out"

# 9. The pre-push bypass does not reach the scan.
VIBESTACK_REDACT_PREPUSH=skip "$BIN/vibe-redact" scan --file "$TMP/aws.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "prepush skip env does not bypass scan" || no "skip env bypassed scan (exit=$rc)"

# 10. The pre-push guard still blocks through the shared matcher.
R="$TMP/repo"; mkdir -p "$R"
(
  cd "$R" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  echo base > a.txt && git add a.txt && git commit -qm base
) >/dev/null 2>&1
base=$(git -C "$R" rev-parse HEAD)
push_rc() { (cd "$R" && printf 'refs/heads/main %s refs/heads/main %s\n' "$1" "$base" | "$BIN/vibe-redact-prepush" >/dev/null 2>&1); echo $?; }
printf '%s\n' "$AWS_KEY" > "$R/b.txt"; git -C "$R" add b.txt; git -C "$R" commit -qm aws
[ "$(push_rc "$(git -C "$R" rev-parse HEAD)")" -eq 1 ] && ok "prepush blocks AWS key" || no "prepush let AWS key through"
git -C "$R" reset -q --hard "$base"
printf '%s\n' "$PEM_HEAD" > "$R/k.pem"; git -C "$R" add k.pem; git -C "$R" commit -qm pem
[ "$(push_rc "$(git -C "$R" rev-parse HEAD)")" -eq 1 ] && ok "prepush blocks private key block" || no "prepush let private key through"
git -C "$R" reset -q --hard "$base"
echo "plain change" > "$R/c.txt"; git -C "$R" add c.txt; git -C "$R" commit -qm clean
[ "$(push_rc "$(git -C "$R" rev-parse HEAD)")" -eq 0 ] && ok "prepush allows a clean push" || no "prepush blocked a clean push"

# 11. A matcher that errors (here: a pattern grep rejects) is never a clean
#     result — neither for scan nor for the pre-push guard.
BROKEN="$TMP/broken"; mkdir -p "$BROKEN"
cp "$BIN/vibe-redact" "$BIN/vibe-redact-prepush" "$BROKEN/"
sed "s/^  'AWS access key|AKIA\[0-9A-Z\]{16}'$/  'AWS access key|['/" "$BIN/vibe-redact-prepush" > "$BROKEN/vibe-redact-prepush"
chmod +x "$BROKEN/vibe-redact-prepush"
grep -qF "'AWS access key|['" "$BROKEN/vibe-redact-prepush" || no "could not plant the broken pattern"
"$BROKEN/vibe-redact" scan --file "$TMP/clean.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a failing matcher makes scan exit 2" || no "failing matcher scan exit=$rc"
clean_tip=$(git -C "$R" rev-parse HEAD)
(cd "$R" && printf 'refs/heads/main %s refs/heads/main %s\n' "$clean_tip" "$base" | "$BROKEN/vibe-redact-prepush" >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a failing matcher blocks the push" || no "failing matcher let a push through"

# 12. The skills that publish text call the scanner and fail closed.
for s in spec document-generate document-release ship; do
  grep -q 'vibe-redact" scan --file' "$ROOT/skills/$s/SKILL.md" \
    && ok "$s calls vibe-redact scan" || no "$s does not call vibe-redact scan"
  grep -q 'REDACT_EXIT: 0' "$ROOT/skills/$s/SKILL.md" \
    && ok "$s passes only on exit 0" || no "$s lacks the exit-0-only rule"
done

# --- Every sink that persists or publishes free text refuses the same secrets ---
#
# A sink is called with one text and answers 0 when it refused it (nothing
# written, push blocked), 1 when it accepted it. Accepting means the text was
# actually stored, so a negative cannot pass by the sink failing for some
# unrelated reason.
SINKS="scan prepush decision review learn question timeline evidence"
export VIBESTACK_PROJECT_SLUG="redact-test"
PROJ="$VIBESTACK_HOME/projects/$VIBESTACK_PROJECT_SLUG"
LR="$TMP/logrepo"; mkdir -p "$LR"
(
  cd "$LR" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  echo base > a.txt && git add a.txt && git commit -qm base
) >/dev/null 2>&1

with_field() {
  python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); d[sys.argv[2]]=sys.argv[3]; print(json.dumps(d))' "$1" "$2" "$3"
}
stored_bytes() { cat "$PROJ"/* 2>/dev/null | wc -c | tr -d ' '; }

# $1 = rc the sink exits with on refusal; the rest is the command.
log_sink() {
  local want="$1" before after rc=0; shift
  before=$(stored_bytes)
  (cd "$LR" && "$@") >/dev/null 2>&1 || rc=$?
  after=$(stored_bytes)
  if [ "$before" = "$after" ] && [ "$rc" -eq "$want" ]; then return 0; fi
  if [ "$before" != "$after" ] && [ "$rc" -eq 0 ]; then return 1; fi
  return 2
}

sink() {
  local name="$1" text="$2" f rc=0
  case "$name" in
    scan)
      f="$TMP/sink.txt"; printf '%s\n' "$text" > "$f"
      scan --file "$f" >/dev/null 2>&1 || rc=$?
      case "$rc" in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac ;;
    prepush)
      printf '%s\n' "$text" > "$R/sink.txt"
      git -C "$R" add sink.txt && git -C "$R" commit -qm sink
      rc=$(push_rc "$(git -C "$R" rev-parse HEAD)")
      git -C "$R" reset -q --hard "$base"
      case "$rc" in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac ;;
    decision)
      log_sink 1 "$BIN/vibe-decision-log" "$(with_field '{"rationale":"r"}' decision "$text")" ;;
    review)
      log_sink 1 "$BIN/vibe-review-log" "$(with_field '{"skill":"review","status":"issues_found"}' summary "$text")" ;;
    learn)
      log_sink 1 "$BIN/vibe-learnings-log" \
        "$(with_field '{"skill":"t","type":"pattern","key":"k1","confidence":5,"source":"observed"}' insight "$text")" ;;
    question)
      log_sink 1 "$BIN/vibe-question-log" "$(with_field '{"skill":"t","question_id":"t:q"}' question_summary "$text")" ;;
    timeline)
      # Best-effort by contract: it never fails the caller, it just drops the event.
      log_sink 0 "$BIN/vibe-timeline-log" "$(with_field '{"skill":"t"}' event "$text")" ;;
    evidence)
      # A refused command line is never run and never recorded (exit 2).
      log_sink 2 "$BIN/vibe-evidence" run --skill t --label s -- printf '%s' "$text" ;;
  esac
}

# The learnings sync plan does not block — it skips a secret-bearing learning.
SP="$TMP/syncplan"; mkdir -p "$SP"
syncplan_skips() {
  : > "$SP/memrain-synced.txt"
  with_field '{"key":"k1","type":"pattern","confidence":5,"ts":"2026-01-01T00:00:00Z"}' insight "$1" > "$SP/learnings.jsonl"
  local out
  out=$("$BIN/vibe-learnings-sync-plan" --project-dir "$SP" 2>&1)
  printf '%s\n' "$out" | grep -q '^skipped (redacted): k1'
}

# 13. The added shapes, each behind every line prefix a pasted diff, shell
#     profile or indented block gives it, refused by every sink.
B16="Zx81Qw7Lm2Pz0Rt5"
NEW_SHAPES=(
  "env-style secret|SERVICE_TOKEN=${B16}Yu9Io3Kj"
  "AWS temporary key|ASIA""QWERTYUIOPASDFGH"
  "DSN credentials|postgres://admin:${B16}@db.internal:5432/app"
  "SecretAccessKey field|\"SecretAccessKey\": \"${B16}Yu9Io3KjAb12Cd34Ef56Gh78\""
)
for entry in "${NEW_SHAPES[@]}"; do
  label="${entry%%|*}"; value="${entry#*|}"
  for prefix in "" "+" " +" "export " "    "; do
    for s in $SINKS; do
      sink "$s" "$prefix$value"; rc=$?
      [ "$rc" -eq 0 ] && ok "$s refuses $label with prefix '$prefix'" \
        || no "$s accepted $label with prefix '$prefix' (rc=$rc)"
    done
  done
  syncplan_skips "$value" && ok "sync plan skips $label" || no "sync plan would push $label"
done

# 13c. Shapes a placeholder rule must not swallow: a generated password with a
#      "$" in it, a long value that happens to end in "...", a docker-compose
#      list item, and a URL whose user name is empty.
SMUGGLED=(
  'DSN with $ in the password|postgres://svc:Xk9$mP2qLz7Rt4@db/app'
  'long value ending in ...|DB_PASSWORD=CorrectHorseBattery123...'
  'YAML list item|      - OPENAI_API_KEY='"${B16}"'Yu9Io3Kj'
  'DSN with no user name|redis://:'"${B16}"'@redis:6379/0'
)
for entry in "${SMUGGLED[@]}"; do
  label="${entry%%|*}"; value="${entry#*|}"
  for s in $SINKS; do
    sink "$s" "$value"; rc=$?
    [ "$rc" -eq 0 ] && ok "$s refuses a $label" || no "$s accepted a $label (rc=$rc)"
  done
done
# A positional parameter is an expansion, not a value: shell scripts pass
# tokens through as "$1".
for s in $SINKS; do
  sink "$s" '    API_TOKEN="$1"'; rc=$?
  [ "$rc" -eq 1 ] && ok "$s passes API_TOKEN=\"\$1\"" || no "$s refused API_TOKEN=\"\$1\" (rc=$rc)"
done
# diff.external would hand the hook a tool's rendering instead of git's diff.
git -C "$R" config diff.external true
sink prepush "SERVICE_TOKEN=${B16}Yu9Io3Kj"; rc=$?
git -C "$R" config --unset diff.external
[ "$rc" -eq 0 ] && ok "prepush scans git's own diff under diff.external" || no "diff.external hid a secret from prepush (rc=$rc)"

# 14. Green path: placeholders, plain URLs and SSH remotes pass every sink.
NEGATIVES=(
  "see https://host/path for details"
  "remote git@host:repo"
  "aws_access_key_id = AKIA""IOSFODNN7EXAMPLE"
  "password: <password>"
  "DATABASE_URL=postgres://user:<password>@host"
  "export API_KEY=your-api-key"
  "\"SecretAccessKey\": \"wJalrXUtnFEMI/K7MDENG/bPxRfiCY""EXAMPLEKEY\""
  "DATABASE_URL=postgres://postgres:postgres@localhost:5432/test"
  "postgres://user:pass@host"
  "postgres://gateway_test:gateway_test@127.0.0.1:5432/gateway_test"
  "local dev uses postgres://user:pass@localhost/db"
  'postgres://${POSTGRES_USER:-crm}:${POSTGRES_PASSWORD}@db/crm'
  '    export NPM_TOKEN=${{ secrets.NPM_TOKEN }}'
  'export GITHUB_TOKEN=$(gh auth token)'
  '  API_KEY=${API_KEY:-}'
  "export OPENAI_API_KEY=sk-..."
)
for value in "${NEGATIVES[@]}"; do
  for s in $SINKS; do
    sink "$s" "$value"; rc=$?
    [ "$rc" -eq 1 ] && ok "$s accepts '$value'" || no "$s refused '$value' (rc=$rc)"
  done
done
for value in "see https://host/path for details" "remote git@host:repo"; do
  syncplan_skips "$value" && no "sync plan skipped '$value'" || ok "sync plan keeps '$value'"
done

# 15. Sync: one canary per pattern the canonical snippet lists, and every sink
#     refuses every canary. A pattern added to the snippet without a canary
#     here, or to one sink and not the others, fails this section.
H40="${B16}Yu9Io3KjAb12Cd34Ef56Gh78"
CANON=(
  "AKIA""QWERTYUIOPASDFGH"
  "aws_secret_access_key = $H40"
  "$GH_TOKEN"
  "github_pat_""11ABCDEFG0123456789_abcdefghijklmnop"
  "xoxb-""1234567890-abcdefABCDEF"
  "sk_live_""Zx81Qw7Lm2Pz0Rt5Yu9Io3Kj"
  "AIza""SyD0123456789abcdefghijklmnopqrstuv"
  "sk-ant-""api03-Zx81Qw7Lm2Pz0Rt5Yu9Io3Kj"
  "sk-proj-""Zx81Qw7Lm2Pz0Rt5Yu9Io3Kj"
  "glpat-""Zx81Qw7Lm2Pz0Rt5Yu9Io3Kj"
  "hf_""Zx81Qw7Lm2Pz0Rt5Yu9Io3KjAb12Cd34"
  "npm_""$B36"
  "dop_v1_""$(printf '0a1b%.0s' $(seq 1 16))"
  "{\"private_key_id\": \"1\", \"private_key\": \"-----BEGIN PRIV""ATE KEY-----\\nMII\"}"
  "$BEARER"
  "SERVICE_TOKEN=${B16}Yu9Io3Kj"
  "$PEM_HEAD"
  "ASIA""QWERTYUIOPASDFGH"
  "postgres://admin:${B16}@db.internal:5432/app"
  "\"SecretAccessKey\": \"$H40\""
)
bullets=$(grep -c '^- `' "$ROOT/lib/snippets/secret-scan-patterns.md")
[ "$bullets" -eq "${#CANON[@]}" ] && ok "one canary per canonical pattern ($bullets)" \
  || no "snippet lists $bullets patterns, the test has ${#CANON[@]} canaries"
for value in "${CANON[@]}"; do
  for s in $SINKS; do
    sink "$s" "$value"; rc=$?
    [ "$rc" -eq 0 ] && ok "$s refuses ${value:0:12}..." || no "$s accepted ${value:0:12}... (rc=$rc)"
  done
done

# The python sinks carry one matcher block, byte-identical in each, whose
# labels are the pre-push list's labels.
block_of() { sed -n '/^# --- secret patterns: begin/,/^# --- secret patterns: end/p' "$1"; }
ref=$(block_of "$BIN/vibe-decision-log")
[ -n "$ref" ] && ok "vibe-decision-log carries the matcher block" || no "vibe-decision-log has no matcher block"
for b in vibe-review-log vibe-learnings-log vibe-question-log vibe-timeline-log vibe-evidence; do
  [ -n "$ref" ] && [ "$(block_of "$BIN/$b")" = "$ref" ] && ok "$b matcher block matches" \
    || no "$b matcher block differs from vibe-decision-log"
done
# macOS /bin/bash 3.2 parses a heredoc inside $(...) as shell text, so a "$("
# in the embedded python breaks the bash-wrapped sinks there and nowhere else.
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]'; then
  for b in vibe-learnings-log vibe-question-log vibe-timeline-log; do
    /bin/bash -n "$BIN/$b" 2>/dev/null && ok "$b parses under /bin/bash 3" || no "$b does not parse under /bin/bash 3"
  done
fi
# A sink that keeps its own copy of the patterns drifts the day the list grows;
# the greptile reply gate scans through the shared matcher instead.
GT="$ROOT/skills/review/greptile-triage.md"
grep -q 'AKIA\[0-9A-Z\]' "$GT" && no "greptile-triage.md carries its own pattern copy" \
  || ok "greptile-triage.md keeps no private pattern copy"
[ "$(grep -c 'vibe-redact" scan --file "$REPLY_FILE"' "$GT")" -ge 2 ] \
  && ok "both greptile reply blocks scan through vibe-redact" || no "a greptile reply block does not scan through vibe-redact"
sh_labels=$(sed -n "s/^  '\([^|]*\)|.*/\1/p" "$BIN/vibe-redact-prepush" | sort)
py_labels=$(printf '%s\n' "$ref" | sed -n 's/^    ("\([^"]*\)", r".*/\1/p' | sort)
[ -n "$sh_labels" ] && [ "$sh_labels" = "$py_labels" ] && ok "python and pre-push lists carry the same labels" \
  || no "label sets differ: pre-push [$(echo $sh_labels)] python [$(echo $py_labels)]"

# 16. The pre-push guard refuses an unresolved merge-conflict marker, but not
#     one quoted in a text or diff fence of a markdown file.
push_file() {
  local path="$1" body="$2" rc
  mkdir -p "$R/$(dirname "$path")"
  printf '%b' "$body" > "$R/$path"
  git -C "$R" add -- "$path" && git -C "$R" commit -qm conflict
  rc=$(push_rc "$(git -C "$R" rev-parse HEAD)")
  git -C "$R" reset -q --hard "$base"
  return "$rc"
}
L7="<<<<<<<"; R7=">>>>>>>"; E7="======="
push_file a.txt "keep\n$L7 HEAD\nours\n$E7\ntheirs\n$R7 feature\n"; rc=$?
[ "$rc" -eq 1 ] && ok "conflict markers block the push" || no "conflict markers pushed (rc=$rc)"
for marker in "$L7 HEAD" "$L7" "$R7 topic"; do
  push_file b.txt "x\n$marker\ny\n"; rc=$?
  [ "$rc" -eq 1 ] && ok "a lone '$marker' blocks" || no "lone '$marker' pushed (rc=$rc)"
done
# Seven "=" under a seven-letter title is a setext heading, not a conflict; it
# counts only beside an opener or closer added to the same file.
push_file README.md "Install\n$E7\n\nrun it\n"; rc=$?
[ "$rc" -eq 0 ] && ok "a setext heading underline is not a marker" || no "setext heading blocked (rc=$rc)"
push_file d.txt "x\n$E7\ny\n$R7 topic\n"; rc=$?
[ "$rc" -eq 1 ] && ok "'$E7' beside a closer still blocks" || no "'$E7' beside a closer pushed (rc=$rc)"
for line in "$E7 note" "${L7}< deeper" "  $L7 indented"; do
  push_file c.txt "$line\n"; rc=$?
  [ "$rc" -eq 0 ] && ok "'$line' is not a marker" || no "'$line' blocked (rc=$rc)"
done
for lang in text diff; do
  push_file "docs/merge.md" "# Merging\n\n\`\`\`$lang\n$L7 HEAD\nours\n$E7\ntheirs\n$R7 feature\n\`\`\`\n"; rc=$?
  [ "$rc" -eq 0 ] && ok "markers in a $lang fence of a .md pass" || no "fenced $lang markers blocked (rc=$rc)"
done
push_file "docs/merge.md" "# Merging\n\n$L7 HEAD\nours\n$E7\ntheirs\n$R7 feature\n"; rc=$?
[ "$rc" -eq 1 ] && ok "markers outside a fence in a .md block" || no "unfenced .md markers pushed (rc=$rc)"
push_file "docs/merge.md" "\`\`\`bash\n$L7 HEAD\necho a\n$E7\necho b\n$R7 feature\n\`\`\`\n"; rc=$?
[ "$rc" -eq 1 ] && ok "markers in a code fence of a .md block" || no "markers in a bash fence pushed (rc=$rc)"
git -C "$R" config diff.noprefix true
push_file "docs/merge.md" "\`\`\`text\n$L7 HEAD\n\`\`\`\n"; rc=$?
git -C "$R" config --unset diff.noprefix
[ "$rc" -eq 0 ] && ok "a fenced .md marker passes under diff.noprefix" || no "diff.noprefix lost the .md path (rc=$rc)"
push_file "notes.txt" "\`\`\`text\n$L7 HEAD\n\`\`\`\n"; rc=$?
[ "$rc" -eq 1 ] && ok "fences only count in .md files" || no "fenced marker in .txt pushed (rc=$rc)"
printf '%b' "$L7 HEAD\n" > "$R/d.txt"; git -C "$R" add d.txt; git -C "$R" commit -qm skip
(cd "$R" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$base" \
  | VIBESTACK_REDACT_PREPUSH=skip "$BIN/vibe-redact-prepush" >/dev/null 2>&1); rc=$?
git -C "$R" reset -q --hard "$base"
[ "$rc" -eq 0 ] && ok "VIBESTACK_REDACT_PREPUSH=skip bypasses the marker guard" || no "skip did not bypass markers (rc=$rc)"

# Value: protects=a live credential-in-URL on a later line or after a placeholder URL is still refused by every sink; fails_when=a sink judges only the first DSN match or lets one placeholder excuse the whole text; why_new=section 14 only feeds single-line placeholders and section 13 only single live values; seam=none
MIXED_DSN="DATABASE_URL=postgres://postgres:postgres@localhost/test
prod=postgres://admin:${B16}@db.internal/app"
for s in $SINKS; do
  sink "$s" "$MIXED_DSN"; rc=$?
  [ "$rc" -eq 0 ] && ok "$s refuses a live DSN after a placeholder DSN" || no "$s accepted a live DSN after a placeholder DSN (rc=$rc)"
  sink "$s" "dev postgres://postgres:postgres@a/t, prod postgres://admin:${B16}@b/app"; rc=$?
  [ "$rc" -eq 0 ] && ok "$s refuses a live DSN on the same line as a placeholder DSN" || no "$s accepted a live DSN beside a placeholder DSN (rc=$rc)"
done

# Value: protects=the documented under-8-character DSN password allowance ends exactly at 8; fails_when=the length rule is dropped or becomes <=8; why_new=section 14 short passwords (pass, postgres) are also in the common-word list so the length rule alone is never exercised; seam=none
for s in $SINKS; do
  sink "$s" "postgres://admin:Kq7xP2m@db.internal/app"; rc=$?
  [ "$rc" -eq 1 ] && ok "$s accepts a 7-character DSN password" || no "$s refused a 7-character DSN password (rc=$rc)"
  sink "$s" "postgres://admin:Kq7xP2mZ@db.internal/app"; rc=$?
  [ "$rc" -eq 0 ] && ok "$s refuses an 8-character DSN password" || no "$s accepted an 8-character DSN password (rc=$rc)"
done

# Value: protects=env-style names containing digits (S3_, OAUTH2_, STRIPE2_) are secrets; fails_when=the name class reverts to [A-Z_] only; why_new=every section 13/15 env canary is SERVICE_TOKEN, which has no digit; seam=none
for s in $SINKS; do
  sink "$s" "S3_SECRET_KEY=${B16}Yu9Io3Kj"; rc=$?
  [ "$rc" -eq 0 ] && ok "$s refuses an env secret whose name has a digit" || no "$s accepted S3_SECRET_KEY (rc=$rc)"
done

# Value: protects=a marker after a closed text fence in a .md is refused and a fenced one added mid-file is excused; fails_when=fence state is not reset on the closing fence, or hunk line numbers are mis-mapped for edits to an existing file; why_new=section 16 only adds whole new files with one fence or none; seam=none
md_base_commit() {
  printf '%b' "# t\n\n\`\`\`text\nours\ntheirs\n\`\`\`\n\nend\n" > "$R/e.md"
  git -C "$R" add e.md; git -C "$R" commit -qm editbase
  md_base=$(git -C "$R" rev-parse HEAD)
}
md_push_edit() {
  local rc
  printf '%b' "$1" > "$R/e.md"
  git -C "$R" add e.md && git -C "$R" commit -qm editmarker
  (cd "$R" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$md_base" \
    | "$BIN/vibe-redact-prepush" >/dev/null 2>&1); rc=$?
  git -C "$R" reset -q --hard "$base"
  return "$rc"
}
md_base_commit
md_push_edit "# t\n\n\`\`\`text\n$L7 HEAD\nours\ntheirs\n\`\`\`\n\nend\n"; rc=$?
[ "$rc" -eq 0 ] && ok "a marker added inside a text fence of an existing .md passes" || no "mid-file fenced marker blocked (rc=$rc)"
md_base_commit
md_push_edit "# t\n\n\`\`\`text\nours\ntheirs\n\`\`\`\n$L7 HEAD\n\nend\n"; rc=$?
[ "$rc" -eq 1 ] && ok "a marker right after a closed text fence in a .md blocks" || no "marker after closed fence pushed (rc=$rc)"

echo ""
echo "redact-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
