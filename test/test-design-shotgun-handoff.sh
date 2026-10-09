#!/usr/bin/env bash
# design-shotgun: approved.json is written from a file (never from shell-spliced
# feedback), records the approved image's absolute path, and refuses a missing
# image; the evolve path opens the confirmed URL before it screenshots; the
# anti-convergence rule defers to DESIGN.md.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
SHOT="$SRC/skills/design-shotgun/SKILL.md"
pass=0; fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
no() { echo "  FAIL $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# extract_block MARKER -> first ```bash block after MARKER
extract_block() {
  python3 -I - "$SHOT" "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
at = text.find(sys.argv[2])
m = re.search(r"```bash\n(.*?)\n```", text[at:], re.S) if at >= 0 else None
if not m:
    sys.exit("no bash block after %r" % sys.argv[2])
sys.stdout.write(m.group(1) + "\n")
PY
}

echo "approved.json"
if extract_block '**Save the approved choice.**' > "$TMP/save.sh"; then
  ok "the save step carries a bash block"
else
  no "the save step carries no bash block"
fi
grep -qF 'echo '"'"'{"approved_variant"' "$SHOT" \
  && no "approved.json is still built by echo" || ok "approved.json is not built by echo"

DDIR="$TMP/designs/hero-20260101"
mkdir -p "$DDIR/round-2"
: > "$DDIR/variant-B.png"; : > "$DDIR/round-2/variant-B.png"
FB='It'"'"'s "close" — $(touch pwned) `touch pwned2`'
printf '%s\n' "$FB" > "$DDIR/approved-feedback.txt"

run_save() {  # run_save ROUND_DIR LETTER -> rc; output in $TMP/out
  sed -e "s|<ROUND_DIR>|$1|" -e "s|<V>|$2|" "$TMP/save.sh" > "$TMP/run.sh"
  (cd "$TMP" && _DESIGN_DIR="$DDIR" bash "$TMP/run.sh") > "$TMP/out" 2>&1
}

rc=0; run_save "$DDIR/round-2" B || rc=$?
if [ "$rc" -eq 0 ] && python3 -I - "$DDIR/approved.json" "$DDIR/round-2/variant-B.png" "$FB" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
assert rec["approved_variant"] == "B", rec
assert rec["approved_path"] == sys.argv[2], rec
assert rec["feedback"] == sys.argv[3], rec
assert rec["screen"] == "hero", rec
PY
then ok "approved.json records the round-2 image path and the feedback verbatim"
else no "approved.json wrong: rc=$rc $(cat "$TMP/out")"; fi
grep -q "^APPROVED_IMAGE: $DDIR/round-2/variant-B.png$" "$TMP/out" \
  && ok "the approved image path is printed" || no "no APPROVED_IMAGE line: $(cat "$TMP/out")"
ls "$TMP" | grep -q pwned && no "the feedback ran as a command" || ok "the feedback never executes"

rm -f "$DDIR/approved.json"
rc=0; run_save "$DDIR" C || rc=$?
[ "$rc" -ne 0 ] && grep -q "is missing; reselect" "$TMP/out" && [ ! -f "$DDIR/approved.json" ] \
  && ok "a missing approved image fails without writing approved.json" \
  || no "missing image: rc=$rc $(cat "$TMP/out")"

echo "evolve screenshot"
if extract_block 'take ONE screenshot' > "$TMP/shot.sh"; then
  ok "the evolve step carries a bash block"
else
  no "the evolve step carries no bash block"
fi
cat > "$TMP/B" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$B_CALLS"
EOF
chmod +x "$TMP/B"
run_shot() {  # run_shot URL_FILE_CONTENT
  : > "$TMP/calls"
  printf '%s\n' "$1" > "$DDIR/current-url.txt"
  (cd "$TMP" && B="$TMP/B" B_CALLS="$TMP/calls" _DESIGN_DIR="$DDIR" bash "$TMP/shot.sh") > "$TMP/out" 2>&1 || true
}
run_shot "http://localhost:3000/pricing"
[ "$(sed -n 1p "$TMP/calls")" = "goto http://localhost:3000/pricing" ] \
  && [ "$(sed -n 2p "$TMP/calls")" = "screenshot $DDIR/current.png" ] \
  && ok "the confirmed URL is opened before the screenshot" || no "calls: $(cat "$TMP/calls")"
run_shot 'javascript:alert(1)'
[ ! -s "$TMP/calls" ] && grep -q "CURRENT_URL_INVALID" "$TMP/out" \
  && ok "a non-http URL is refused" || no "bad URL: $(cat "$TMP/calls") $(cat "$TMP/out")"

echo "anti-convergence"
grep -qF 'When a DESIGN.md exists, it decides' "$SHOT" \
  && ok "the anti-convergence rule defers to DESIGN.md" || no "anti-convergence ignores DESIGN.md"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
