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
#   - every skill that writes approved.json records the image in approved_path;
#   - design-shotgun Step 3c generates every variant with one
#     `vibe-design variants --briefs-file` call (run here with a stub designer:
#     one call, briefs never executed), with no subagent fan-out or cp; Step 3d
#     retries failed letters once, caps regeneration, and sets a discarded
#     variant aside without overwriting an earlier one;
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

echo "approved.json names its image"
# A letter is ambiguous once a second round saved variant-A-2.png; /design-html
# opens the record's approved_path, so every writer must store one.
writers="$(python3 -I - "$SRC/skills" <<'PY'
import glob, os, re, sys
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*", "SKILL.md"))):
    text = open(path, encoding="utf-8").read()
    for block in re.findall(r"```bash\n(.*?)\n```", text, re.S):
        if '"approved.json"' in block and "json.dump" in block:
            print("%s %s" % (os.path.basename(os.path.dirname(path)), "yes" if '"approved_path"' in block else "no"))
PY
)"
[ -n "$writers" ] && ok "found skills that write approved.json" || no "found no approved.json writer"
while read -r name has; do
  [ -n "$name" ] || continue
  [ "$has" = yes ] && ok "$name records approved_path" || no "$name writes approved.json without approved_path"
done <<<"$writers"

echo "design-shotgun generation"
SHOT="$SRC/skills/design-shotgun/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sect() { awk -v s="$2" -v e="$3" '$0 ~ s {on=1; next} on && $0 ~ e {on=0} on' "$1"; }
sect "$SHOT" '^### Step 3c' '^### Step 3d' > "$TMP/3c.md"
sect "$SHOT" '^### Step 3d' '^## Step 4' > "$TMP/3d.md"
[ -s "$TMP/3c.md" ] && [ -s "$TMP/3d.md" ] || { no "Step 3c/3d not found in design-shotgun"; echo "$pass passed, $fail failed"; exit 1; }
grep -qF -- '--briefs-file' "$TMP/3c.md" && ok "Step 3c generates every variant with one --briefs-file call" \
  || no "Step 3c does not use --briefs-file"
grep -qF 'timeout: 600000' "$TMP/3c.md" && ok "the one Bash call carries timeout: 600000" || no "no timeout: 600000 on the batch call"
grep -qF 'With your Write tool, write' "$TMP/3c.md" && grep -qF 'briefs.json' "$TMP/3c.md" \
  && ok "briefs.json is written with the Write tool" || no "briefs.json is not written with the Write tool"
for gone in 'subagent_type' 'Agent prompt template' 'cp "$SAVED"' 'mktemp -d /tmp/variant'; do
  grep -qF -- "$gone" "$TMP/3c.md" && no "Step 3c still has '$gone'" || ok "Step 3c has no '$gone'"
done
grep -qF '_IMAGES' "$TMP/3d.md" && no "Step 3d keeps the dead _IMAGES list" || ok "Step 3d has no _IMAGES list"
tr '\n' ' ' < "$TMP/3d.md" | grep -qiE 'retry (each )?failed letters? once' \
  && ok "Step 3d retries failed letters once" || no "Step 3d has no single retry of failed letters"
tr '\n' ' ' < "$TMP/3d.md" | grep -qiE 'regenerat[a-z]* .{0,60}at most 2|2 regenerations' \
  && ok "Step 3d caps regeneration at 2" || no "Step 3d has no regeneration cap"

# The batch block, run with a stub designer: one call, the briefs file and the
# round dir as written, and the brief text never on the command line.
python3 -I - "$TMP/3c.md" > "$TMP/batch.sh" <<'PY'
import re, sys
blocks = re.findall(r"```bash\n(.*?)\n```", open(sys.argv[1], encoding="utf-8").read(), re.S)
hit = [b for b in blocks if "--briefs-file" in b]
sys.stdout.write(hit[0] + "\n" if hit else "")
PY
mkdir -p "$TMP/home/bin" "$TMP/round"
cat > "$TMP/home/bin/vibe-design" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
echo "requested: 2"; echo "saved: $4/variant-A.png"; echo "saved: $4/variant-B.png"; echo "failures: 0"
SH
chmod +x "$TMP/home/bin/vibe-design"
printf '[{"brief": "Hero $(touch %s/pwned) `touch %s/pwned2`"}, {"brief": "Two"}]\n' "$TMP" "$TMP" > "$TMP/round/briefs.json"
if [ -s "$TMP/batch.sh" ]; then
  sed -i.bak "s|<ROUND_DIR>|$TMP/round|g" "$TMP/batch.sh"
  : > "$TMP/calls"
  (cd "$TMP" && VIBESTACK_HOME="$TMP/home" STUB_CALLS="$TMP/calls" bash "$TMP/batch.sh") > "$TMP/batch.out" 2>&1
  { [ "$(wc -l < "$TMP/calls" | tr -d ' ')" = 1 ] \
    && grep -qx -- "variants --briefs-file $TMP/round/briefs.json --output-dir $TMP/round" "$TMP/calls"; } \
    && ok "the block makes one designer call on the round's briefs file" || no "batch call: $(cat "$TMP/calls") / $(cat "$TMP/batch.out")"
  ls "$TMP" | grep -q pwned && no "a brief ran as a command" || ok "the briefs never execute"
else
  no "Step 3c carries no runnable --briefs-file block"
fi

# Setting a discarded variant aside frees its name for the regeneration, and
# never overwrites an earlier rejection.
python3 -I - "$TMP/3d.md" > "$TMP/aside.sh" <<'PY'
import re, sys
blocks = re.findall(r"```bash\n(.*?)\n```", open(sys.argv[1], encoding="utf-8").read(), re.S)
hit = [b for b in blocks if "rejected-" in b]
sys.stdout.write(hit[0] + "\n" if hit else "")
PY
if [ -s "$TMP/aside.sh" ]; then
  R="$TMP/aside"; mkdir -p "$R"; echo first > "$R/variant-B.png"
  sed -e "s|<ROUND_DIR>|$R|g" -e "s|<LETTER>|B|g" "$TMP/aside.sh" > "$TMP/aside-run.sh"
  bash "$TMP/aside-run.sh" > /dev/null 2>&1; echo second > "$R/variant-B.png"; bash "$TMP/aside-run.sh" > /dev/null 2>&1
  { [ ! -e "$R/variant-B.png" ] && [ "$(cat "$R/rejected-B-1.png")" = first ] && [ "$(cat "$R/rejected-B-2.png")" = second ]; } \
    && ok "a discarded variant is set aside without overwriting an earlier one" || no "set-aside: $(ls "$R")"
else
  no "Step 3d carries no set-aside block for a discarded variant"
fi

echo "documented contract"
row="$(grep -F '| `vibe-design` |' "$SRC/docs/internals.md" || true)"
for want in 'saved: <path>' 'failures:' 'Exit 0 all saved, 3 partial, 2 nothing saved' 'never overwrites'; do
  grep -qF -- "$want" <<<"$row" && ok "internals documents '$want'" || no "internals row lacks '$want'"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
