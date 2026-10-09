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

echo ""
echo "redact-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
