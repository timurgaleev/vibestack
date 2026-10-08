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
#   - design-shotgun's per-variant agents stage into a fresh mktemp directory and
#     copy the printed `saved:` path;
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
grep -qF 'cp "<the saved: path>"' "$SHOT" \
  && ok "agents copy the printed saved: path" || no "agents copy an assumed file name"

echo "documented contract"
row="$(grep -F '| `vibe-design` |' "$SRC/docs/internals.md" || true)"
for want in 'saved: <path>' 'failures:' 'Exit 0 all saved, 3 partial, 2 nothing saved' 'never overwrites'; do
  grep -qF -- "$want" <<<"$row" && ok "internals documents '$want'" || no "internals row lacks '$want'"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
