#!/usr/bin/env bash
# design-shotgun: approved.json is written from a file (never from shell-spliced
# feedback), records the approved image's absolute path, and refuses a missing
# image; it carries an approved archetype and section outline to /design-html and
# refuses an unknown archetype; the evolve path opens the confirmed URL before it
# screenshots; the anti-convergence rule defers to DESIGN.md; Step 1 reads
# PRODUCT.md, Step 2 flags a conflict with a strong taste learning and prints the
# approved.json files it found. Every Bash call is a fresh shell, so
# each block runs with _DESIGN_DIR and B unset and gets them only from the
# placeholders the model fills with what earlier blocks printed.
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

run_save() {  # run_save ROUND_DIR LETTER [ARCHETYPE SECTIONS] -> rc; output in $TMP/out
  sed -e "s|<ROUND_DIR>|$1|" -e "s|<V>|$2|" -e "s|<DESIGN_DIR>|$DDIR|" \
      -e "s|<ARCHETYPE>|${3:-}|" -e "s|<SECTIONS>|${4:-}|" "$TMP/save.sh" > "$TMP/run.sh"
  (cd "$TMP" && env -u _DESIGN_DIR -u B bash "$TMP/run.sh") > "$TMP/out" 2>&1
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

echo "archetype hand-off"
rm -f "$DDIR/approved.json"
rc=0; run_save "$DDIR" B classic-hero "hero,proof,pricing,faq" || rc=$?
if [ "$rc" -eq 0 ] && python3 -I - "$DDIR/approved.json" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
assert rec["archetype"] == "classic-hero", rec
assert rec["sections"] == ["hero", "proof", "pricing", "faq"], rec
PY
then ok "approved.json records the approved archetype and section outline"
else no "archetype not recorded: rc=$rc $(cat "$TMP/out")"; fi
rm -f "$DDIR/approved.json"
rc=0; run_save "$DDIR" B || rc=$?
[ "$rc" -eq 0 ] && python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit("archetype" in r or "sections" in r)' "$DDIR/approved.json" \
  && ok "a screen without an archetype records neither key" || no "empty archetype: rc=$rc $(cat "$TMP/out")"
rm -f "$DDIR/approved.json"
rc=0; run_save "$DDIR" B bento "hero" || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$DDIR/approved.json" ] \
  && ok "an archetype outside the four is refused" || no "unknown archetype accepted: rc=$rc"
rc=0; run_save "$DDIR" B comparison "" || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$DDIR/approved.json" ] \
  && ok "an archetype without its section outline is refused" || no "archetype without sections accepted: rc=$rc"
grep -qF 'classic-hero, long-form-story, minimal-conversion, comparison' "$SHOT" \
  && grep -qF 'same primary action' "$SHOT" \
  && ok "Step 3a varies the archetype and keeps the primary action identical" \
  || no "Step 3a does not vary the page archetype"
HTML="$SRC/skills/design-html/SKILL.md"
sed -n '/^## Step 1: Design Analysis/,/^## Step 2/p' "$HTML" | grep -qF '`archetype` and `sections`' \
  && ok "/design-html Step 1 takes the approved archetype and sections" \
  || no "/design-html ignores the approved archetype"

echo "context and taste"
grep -qF 'cat PRODUCT.md 2>/dev/null | head -120' "$SHOT" \
  && ok "Step 1 reads PRODUCT.md" || no "Step 1 ignores PRODUCT.md"
sed -n '/^## Step 2: Taste Memory/,/^## Step 3/p' "$SHOT" > "$TMP/step2"
grep -qF 'confidence 7 or higher' "$TMP/step2" && grep -qF 'one-off' "$TMP/step2" \
  && ok "a request against a strong taste learning is flagged" || no "no taste-conflict prompt"
# The taste block must show the model what it found; a bare assignment prints nothing.
if extract_block '**Per-session approved.json files' > "$TMP/taste.sh"; then
  VH="$TMP/vh"; mkdir -p "$VH/projects/demo/designs/hero-20260101" "$VH/bin"
  echo '{}' > "$VH/projects/demo/designs/hero-20260101/approved.json"
  printf '#!/bin/sh\necho SLUG=demo\n' > "$VH/bin/vibe-slug"; chmod +x "$VH/bin/vibe-slug"
  (cd "$TMP" && VIBESTACK_HOME="$VH" bash "$TMP/taste.sh") > "$TMP/taste.out" 2>&1 || true
  grep -qF "$VH/projects/demo/designs/hero-20260101/approved.json" "$TMP/taste.out" \
    && ok "the taste block prints the approved.json files it found" \
    || no "the taste block finds approved.json files but prints none: '$(cat "$TMP/taste.out")'"
else
  no "Step 2 carries no taste block"
fi

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
  sed -e "s|<DESIGN_DIR>|$DDIR|" -e "s|<BROWSE_BIN>|$TMP/B|" "$TMP/shot.sh" > "$TMP/shot-run.sh"
  (cd "$TMP" && env -u _DESIGN_DIR -u B B_CALLS="$TMP/calls" bash "$TMP/shot-run.sh") > "$TMP/out" 2>&1 || true
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
