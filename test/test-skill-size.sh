#!/usr/bin/env bash
# Rendered-size guard: every skill, rendered the way ./install writes it
# (include directives expanded), stays at or under CEILING bytes. Snippets grow
# every skill that includes them at once, so the source file alone says little.
# The ceiling sits above the largest skill that loads fine today (ship, about
# 227 KB): crossing it is a prompt to trim or move text into sub-docs before
# the next addition, not proof that a host rejects the file.
#
# Measures ${VIBESTACK_REPO_ROOT:-<this repo>}; the fixture cases below always
# run against throwaway trees so a guard that stopped measuring cannot pass.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$ROOT/bin/vibe-render-skill"
TREE="${VIBESTACK_REPO_ROOT:-$ROOT}"
CEILING=240000
TMP="$(mktemp -d)"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

# measure_tree <repo-root> <out-dir> — renders every skills/*/SKILL.md, prints
# the five largest and every skill over the ceiling. Fails on any skill over
# the ceiling, any render error, or a tree with no skills at all.
measure_tree() {
  local root="$1" out="$2" src name rc=0 sizes="$2/sizes.txt"
  mkdir -p "$out"; : > "$sizes"
  for src in "$root"/skills/*/SKILL.md; do
    [ -f "$src" ] || continue
    name="$(basename "$(dirname "$src")")"
    if ! VIBESTACK_REPO_ROOT="$root" bash "$RENDER" "$src" "$out/$name/SKILL.md" 2>"$out/$name.err"; then
      echo "render failed: $name: $(head -1 "$out/$name.err")"
      rc=1; continue
    fi
    printf '%s %s\n' "$(wc -c < "$out/$name/SKILL.md" | tr -d ' ')" "$name" >> "$sizes"
  done
  if [ ! -s "$sizes" ]; then
    echo "no rendered skills under $root/skills"
    return 1
  fi
  echo "largest rendered skills (ceiling $CEILING B):"
  sort -rn "$sizes" | head -5 | while read -r bytes name; do printf '  %7d  %s\n' "$bytes" "$name"; done
  while read -r bytes name; do
    if [ "$bytes" -gt "$CEILING" ]; then
      echo "over ceiling: $name renders to $bytes B (> $CEILING B)"
      rc=1
    fi
  done < "$sizes"
  return "$rc"
}

# mkskill <tree> <name> <bytes> — a SKILL.md of exactly <bytes> bytes.
mkskill() {
  mkdir -p "$1/skills/$2" "$1/lib/snippets"
  python3 -I -c 'import sys
n = int(sys.argv[1]); h = "# demo\n"; b = n - len(h)
tail = "x" * (b % 1000 - 1) + "\n" if b % 1000 else ""
sys.stdout.write(h + ("x" * 999 + "\n") * (b // 1000) + tail)' "$3" > "$1/skills/$2/SKILL.md"
}

echo "== fixtures =="

t="$TMP/over"; mkskill "$t" small 2000; mkskill "$t" big $((CEILING + 1))
out=$(measure_tree "$t" "$TMP/out-over"); rc=$?
[ "$rc" -eq 1 ] && grep -q "over ceiling: big renders to $((CEILING + 1)) B" <<<"$out" \
  && ok "a skill one byte over the ceiling fails and is named" || no "oversized skill passed (rc=$rc): $out"

t="$TMP/edge"; mkskill "$t" edge "$CEILING"
out=$(measure_tree "$t" "$TMP/out-edge"); rc=$?
[ "$rc" -eq 0 ] && grep -q " $CEILING  edge" <<<"$out" \
  && ok "a skill exactly at the ceiling passes" || no "skill at the ceiling failed (rc=$rc): $out"

t="$TMP/inc"; mkskill "$t" host 2000; mkskill "$t" pad $((CEILING - 1000))
mv "$t/skills/pad/SKILL.md" "$t/lib/snippets/pad.md"; rm -r "$t/skills/pad"
printf '{{include lib/snippets/pad.md}}\n' >> "$t/skills/host/SKILL.md"
out=$(measure_tree "$t" "$TMP/out-inc"); rc=$?
[ "$rc" -eq 1 ] && grep -q "over ceiling: host renders" <<<"$out" \
  && ok "a small source pushed over by an included snippet fails" || no "include growth not measured (rc=$rc): $out"

t="$TMP/broken"; mkskill "$t" demo 2000
printf '{{include lib/snippets/missing.md}}\n' >> "$t/skills/demo/SKILL.md"
out=$(measure_tree "$t" "$TMP/out-broken"); rc=$?
[ "$rc" -eq 1 ] && grep -q "render failed: demo" <<<"$out" \
  && ok "a skill that fails to render fails the guard" || no "render error passed (rc=$rc): $out"

mkdir -p "$TMP/empty/skills"
out=$(measure_tree "$TMP/empty" "$TMP/out-empty"); rc=$?
[ "$rc" -eq 1 ] && ok "a tree with no skills fails the guard" || no "empty tree passed (rc=$rc): $out"

echo
echo "== $TREE =="
if measure_tree "$TREE" "$TMP/out-tree"; then ok "every rendered skill is within $CEILING B"; else no "rendered skill size guard"; fi

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
