#!/usr/bin/env bash
# test-design-saved-paths.sh — every skill that runs `vibe-design variants` uses
# the paths the run printed on its `saved:` lines.
#
# vibe-design never overwrites: a second round into the same directory saves
# variant-A-2.png and leaves the first round's variant-A.png in place. A skill
# that reads a fixed variant-A.png afterwards shows the previous round's image
# while the run reports success.
#
# Covers:
#   - no skill or snippet reads a fixed variant-<letter>.png or variant-<CHOSEN>
#     path, or stages into a shared /tmp/variant-<letter>/ directory;
#   - every skill that calls `$D variants` tells the model to use `saved:` paths;
#   - design-shotgun's per-variant agent block, run with a stub designer, stages
#     into a fresh mktemp directory, copies the printed `saved:` path, and leaves
#     no staging directory behind on success, failure or exhausted retries;
#   - the vibe-design row in docs/internals.md documents the output contract.
#
# Usage: test/test-design-saved-paths.sh [repo-root]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

echo "no fixed variant file names"
fixed="$(grep -rnE '/variant-[A-J]\.png|variant-<CHOSEN>|/tmp/variant-\{letter\}/' \
  "$SRC/skills" "$SRC/lib/snippets" --include='*.md' || true)"
if [ -z "$fixed" ]; then
  ok "no skill reads a fixed variant path"
else
  no "fixed variant paths remain:"; printf '%s\n' "$fixed" | sed "s|^$SRC/|       |"
fi

echo "callers use saved: paths"
callers="$(grep -rlE '\$D variants|\{\$D path\} variants' "$SRC/skills" --include='SKILL.md' | sort)"
[ -n "$callers" ] && ok "found skills that generate variants" || no "found no skill that generates variants"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  name="$(basename "$(dirname "$f")")"
  if grep -qF '`saved:`' "$f"; then ok "$name uses the printed saved: paths"
  else no "$name runs \$D variants without naming the saved: paths"; fi
done <<<"$callers"

echo "design-shotgun staging"
SHOT="$SRC/skills/design-shotgun/SKILL.md"
grep -qE 'STAGE=\$\(mktemp -d /tmp/variant-\{letter\}\.XXXXXX\)' "$SHOT" \
  && ok "each agent stages into a fresh mktemp dir" || no "agents share a fixed staging dir"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The per-variant agent block with its placeholders filled. The letter is unique
# to this run, so any /tmp staging dir it leaves behind is ours alone.
L="t$$x"
DDIR="$TMP/designs"; mkdir -p "$DDIR" "$TMP/bin"
if python3 -I - "$SHOT" "$TMP/stub-design" "$DDIR" "$L" > "$TMP/agent.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
at = text.find("**Agent prompt template**")
m = re.search(r"```bash\n(.*?)\n```", text[at:], re.S) if at >= 0 else None
if not m:
    sys.exit("no bash block in the agent prompt template")
block = m.group(1)
for k, v in (("{absolute path to $D binary}", sys.argv[2]),
             ("{_DESIGN_DIR absolute path}", sys.argv[3]), ("{letter}", sys.argv[4])):
    block = block.replace(k, v)
sys.stdout.write(block + "\n")
PY
then ok "the agent prompt carries a runnable staging block"
else no "the agent prompt carries no runnable staging block"; fi
cat > "$TMP/stub-design" <<'EOF'
#!/usr/bin/env bash
out="."; brief=""
while [ $# -gt 0 ]; do
  case "$1" in --output-dir) out="$2"; shift 2 ;; --brief) brief="$2"; shift 2 ;; *) shift ;; esac
done
echo x >> "$STUB_CALLS"
case "$STUB_MODE" in
  ok) printf '%s' "$brief" > "$out/variant-A.png"; echo "saved: $out/variant-A.png" ;;
  fail) echo "DESIGN_ERROR: request failed (HTTP 500): boom"; exit 2 ;;
  limit) echo "DESIGN_ERROR: request failed (HTTP 429): Rate limit reached"; exit 2 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sleep"   # retries without the wait
chmod +x "$TMP/stub-design" "$TMP/bin/sleep"
printf '%s\n' 'Hero "quoted" $(touch pwned) `touch pwned2`' > "$DDIR/brief-$L.txt"

run_agent() {  # run_agent MODE -> exit code; output in $TMP/out-MODE
  : > "$TMP/calls"
  (cd "$TMP" && STUB_MODE="$1" STUB_CALLS="$TMP/calls" PATH="$TMP/bin:$PATH" bash "$TMP/agent.sh") \
    > "$TMP/out-$1" 2>&1
}
leftover() { ls -d /tmp/variant-"$L".* 2>/dev/null || true; }
calls() { wc -l < "$TMP/calls" | tr -d ' '; }

rc=0; run_agent ok || rc=$?
[ "$rc" -eq 0 ] && grep -q "^VARIANT_${L}_DONE:" "$TMP/out-ok" \
  && cmp -s "$DDIR/brief-$L.txt" <(printf '%s\n' "$(cat "$DDIR/variant-$L.png")") \
  && ok "a saved variant is copied from the printed saved: path" || no "success run: rc=$rc $(cat "$TMP/out-ok")"
[ -z "$(leftover)" ] && ok "no staging dir is left after a success" || no "staging dir left after success: $(leftover)"
rc=0; run_agent fail || rc=$?
[ "$rc" -ne 0 ] && grep -q "^VARIANT_${L}_FAILED: DESIGN_ERROR" "$TMP/out-fail" && [ "$(calls)" = 1 ] \
  && ok "a failed generation reports FAILED without retrying" || no "failure run: rc=$rc $(cat "$TMP/out-fail")"
[ -z "$(leftover)" ] && ok "no staging dir is left after a failure" || no "staging dir left after failure: $(leftover)"
rc=0; run_agent limit || rc=$?
[ "$rc" -ne 0 ] && grep -q "^VARIANT_${L}_RATE_LIMITED:" "$TMP/out-limit" && [ "$(calls)" = 4 ] \
  && ok "a rate limit is retried 3 times, then reported" || no "rate-limit run: rc=$rc calls=$(calls) $(cat "$TMP/out-limit")"
[ -z "$(leftover)" ] && ok "no staging dir is left after retries run out" || no "staging dir left after retries: $(leftover)"
rm -f "$DDIR/brief-$L.txt"
rc=0; run_agent ok || rc=$?
[ "$rc" -ne 0 ] && grep -q "^VARIANT_${L}_FAILED: brief not written" "$TMP/out-ok" && [ "$(calls)" = 0 ] \
  && ok "a missing brief fails before the designer runs" || no "missing brief: rc=$rc $(cat "$TMP/out-ok")"
ls "$TMP" | grep -q pwned && no "the brief ran as a command" || ok "the brief never executes"
grep -qF 'With your Write tool, write the brief below verbatim' "$SHOT" \
  && ok "agents write the brief with the Write tool" || no "agents do not write the brief with the Write tool"
for d in $(leftover); do rm -rf "$d"; done

echo "documented contract"
row="$(grep -F '| `vibe-design` |' "$SRC/docs/internals.md" || true)"
for want in 'saved: <path>' 'failures:' 'Exit 0 all saved, 3 partial, 2 nothing saved' 'never overwrites'; do
  grep -qF -- "$want" <<<"$row" && ok "internals documents '$want'" || no "internals row lacks '$want'"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
