#!/usr/bin/env bash
# test-design-html.sh — /design-html instructions that the model can actually follow.
#
# Covers:
#   - no reference to a vendored Pretext bundle (none ships), a classic-script
#     inline, a window.Pretext global, or a nonexistent './pretext-inline.js';
#   - the wiring patterns and the cheat sheet use the real Pretext signatures
#     (layoutNextLine takes a cursor and no lineHeight, advances with result.end;
#     layoutWithLines lines carry no x/y; walkLineRanges passes a line object);
#   - every ```js block parses as an ES module;
#   - the three verification screenshots set the viewport first (screenshot has
#     no width flag), load the http preview rather than file://, and rebind $B
#     from the SETUP-printed placeholder (run with $B unset);
#   - the four input-detection checks each derive the slug, so they find the
#     project's plans and designs when run with SLUG unset;
#   - the CDN import pins an exact Pretext version;
#   - $_SERVER_PID / $_PORT are never read in a bash block other than the one
#     that sets them, since each block is a fresh shell, and the port is read
#     only once the server listens;
#   - Case A opens the image approved.json's approved_path names, and every
#     skill that writes approved.json records that field.
#
# Usage: test/test-design-html.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

R="$TMP/r/design-html/SKILL.md"
VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/design-html/SKILL.md" "$R" \
  >/dev/null 2>&1 || { echo "design-html: render failed" >&2; exit 1; }

absent() { # absent "<label>" "<ERE>"
  if grep -Eq -- "$2" "$R"; then no "$1"; grep -En -- "$2" "$R" | head -3 | sed 's/^/       /'; else ok "$1"; fi
}
present() { # present "<label>" "<fixed string>"
  if grep -Fq -- "$2" "$R"; then ok "$1"; else no "$1"; fi
}

echo "Pretext source"
absent "no vendored bundle lookup" 'vendor/pretext\.js|VENDOR_MISSING'
absent "no './pretext-inline.js' import" 'pretext-inline\.js'
absent "no window.Pretext global" 'window\.Pretext'
present "CDN import sits in a module script" '<script type="module">'
present "CDN import pins an exact esm.sh version" "from 'https://esm.sh/@chenglou/pretext@0.0.9'"

echo "Pretext signatures"
absent "layoutNextLine never takes state or lineHeight" 'layoutNextLine\(segs, (state|cursor, [A-Za-z]+, lineHeight)'
absent "no result.state cursor" 'result\.state'
absent "layoutWithLines lines carry no x/y" 'line\.(x|y)[^A-Za-z]|\{text, width, x, y\}'
absent "walkLineRanges callback is not (lineCount, startIdx, endIdx)" 'onLine\(lineCount|\(lineCount, startIdx, endIdx\)'
present "cheat sheet: layoutNextLine(segs, cursor, maxWidth)" 'layoutNextLine(segs, cursor, maxWidth)'
present "cheat sheet: walkLineRanges returns lineCount" 'walkLineRanges(segs, maxWidth, onLine) → lineCount'
present "pattern 3 advances with result.end" 'cursor = result.end'
present "pattern 2 callback reads line.width" 'widest = Math.max(widest, line.width)'

if command -v node >/dev/null 2>&1; then
  python3 -I - "$R" "$TMP/js" <<'PY'
import os, re, sys
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for i, b in enumerate(re.findall(r'^```js\n(.*?)^```', open(src).read(), re.S | re.M)):
    open(os.path.join(out, f'block{i}.mjs'), 'w').write(b)
PY
  n=0
  for f in "$TMP"/js/*.mjs; do
    [ -f "$f" ] || continue
    n=$((n+1))
    if node --check "$f" >/dev/null 2>&1; then ok "js block $(basename "$f") parses"; else no "js block $(basename "$f") parses"; fi
  done
  [ "$n" -ge 4 ] && ok "found the four wiring patterns ($n js blocks)" || no "found the four wiring patterns ($n js blocks)"
else
  echo "  skip node not installed; js blocks not parsed"
fi

echo "Viewport verification"
absent "screenshot is never given a --width flag" 'screenshot [^`]*--width'
absent "verification never loads file://" 'goto "?file://'
VB="$(python3 -I - "$R" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
i = s.index('### Verification Screenshots')
m = re.search(r'^```bash\n(.*?)^```', s[i:], re.S | re.M)
print(m.group(1) if m else '')
PY
)"
for w in 375 768 1440; do
  if printf '%s\n' "$VB" | grep -A1 -E "^\\\$B viewport ${w}x[0-9]+$" | grep -Eq '^\$B screenshot '; then
    ok "viewport ${w} set right before a screenshot"
  else
    no "viewport ${w} set right before a screenshot"
  fi
done
printf '%s\n' "$VB" | grep -Eq '^B=' && ok "verification block rebinds \$B" || no "verification block rebinds \$B"
# The block runs in a fresh shell: $B comes from the SETUP-printed placeholder,
# never from a path only one runtime installs.
FS="$TMP/fs"; mkdir -p "$FS/home/.vibestack/bin" "$FS/work"
printf '#!/usr/bin/env bash\necho "$*" >> "$FS_CALLS"\n' > "$FS/browse"; chmod +x "$FS/browse"
printf '%s\n' "$VB" | sed -e "s|<BROWSE_BIN>|$FS/browse|" -e 's|<SERVER URL>|http://127.0.0.1:1/finalized.html|' > "$FS/verify.sh"
(cd "$FS/work" && env -u B -u CLAUDE_SKILL_DIR HOME="$FS/home" PATH="/usr/bin:/bin" FS_CALLS="$FS/calls" bash "$FS/verify.sh") >/dev/null 2>&1
[ "$(grep -c '' "$FS/calls" 2>/dev/null)" = 7 ] && [ "$(head -1 "$FS/calls")" = "goto http://127.0.0.1:1/finalized.html" ] \
  && ok "verification drives the browse path SETUP printed, with \$B unset" || no "verification with \$B unset: $(cat "$FS/calls" 2>/dev/null)"

echo "Input detection in fresh shells"
# Each check derives the slug itself; none relies on a SLUG an earlier block set.
printf '#!/usr/bin/env bash\necho SLUG=demo\n' > "$FS/home/.vibestack/bin/vibe-slug"; chmod +x "$FS/home/.vibestack/bin/vibe-slug"
P="$FS/home/.vibestack/projects/demo"; mkdir -p "$P/ceo-plans" "$P/designs/x"
: > "$P/ceo-plans/plan.md"; : > "$P/designs/x/approved.json"; : > "$P/designs/x/variant-A.png"; : > "$P/designs/x/finalized.html"
python3 -I - "$R" "$FS" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
i = s.index('## Step 0: Input Detection')
for n, b in enumerate(re.findall(r'^```bash\n(.*?)^```', s[i:], re.S | re.M)[:4]):
    open("%s/detect-%d.sh" % (sys.argv[2], n), "w").write(b)
PY
for n in 0 1 2 3; do
  (cd "$FS/work" && env -u SLUG HOME="$FS/home" bash "$FS/detect-$n.sh") >> "$FS/detect.out" 2>&1
done
for w in "CEO_PLAN: $P/ceo-plans/plan.md" "APPROVED: $P/designs/x/approved.json" \
         "VARIANTS: $P/designs/x/variant-A.png" "FINALIZED: $P/designs/x/finalized.html"; do
  grep -qxF "$w" "$FS/detect.out" && ok "fresh-shell detection finds ${w%%:*}" || no "detection missed ${w%%:*}: $(cat "$FS/detect.out")"
done

echo "Server PID/URL across blocks"
LEAKS="$(python3 -I - "$R" <<'PY'
import re, sys
for b in re.findall(r'^```bash\n(.*?)^```', open(sys.argv[1]).read(), re.S | re.M):
    if '_SERVER_PID=$!' in b:
        continue
    if re.search(r'\$\{?_(SERVER_PID|PORT)\b', b):
        print(b.strip().splitlines()[0])
PY
)"
[ -z "$LEAKS" ] && ok "no later bash block reads \$_SERVER_PID/\$_PORT" || { no "a later bash block reads \$_SERVER_PID/\$_PORT"; echo "       $LEAKS"; }
absent "user-facing text does not quote \$_PORT" 'running at http://localhost:\$_PORT'
present "kill uses the remembered PID" 'kill <PID>'

present "the port is read only once the server is listening" '-sTCP:LISTEN'
present "the URL names the address the server binds" 'SERVER: http://127.0.0.1:$_PORT/finalized.html'
absent "no localhost URL for a 127.0.0.1-bound server" 'http://localhost:'

echo "approved.json handoff"
present "Case A opens the image approved_path names" "the file the record's \`approved_path\` names"
present "Case A stops when the approved image is gone" 'substitute another variant'
# Every skill that writes approved.json for design-html to read records the image path.
for w in design-shotgun design-consultation; do
  grep -Fq '"approved_path": image' "$SRC/skills/$w/SKILL.md" \
    && ok "$w records approved_path" || no "$w writes approved.json without approved_path"
done

echo
echo "design-html: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
