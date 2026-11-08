#!/usr/bin/env bash
# Compaction re-anchor guard: every skill, rendered the way ./install writes it,
# carries the re-anchor note within its first HEAD_BYTES bytes. A host that
# re-attaches a skill after compaction may keep only the head of the file; the
# note tells the model to re-read the full SKILL.md from disk, so it has to sit
# in the part that survives, ahead of the shared preamble.
#
# Measures ${VIBESTACK_REPO_ROOT:-<this repo>}; the fixture cases below always
# run against throwaway trees so a guard that stopped looking cannot pass.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$ROOT/bin/vibe-render-skill"
TREE="${VIBESTACK_REPO_ROOT:-$ROOT}"
HEAD_BYTES=20000
LINE1='If this session was compacted, the copy of this skill in context may be cut off.'
LINE2='Read `${CLAUDE_SKILL_DIR}/SKILL.md` from disk and resume at the step you are on.'
TMP="$(mktemp -d)"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

# check_tree <repo-root> <out-dir> — renders every skills/*/SKILL.md and names
# each one whose first HEAD_BYTES bytes lack either line of the note. Fails on
# any such skill, any render error, or a tree with no skills at all.
check_tree() {
  local root="$1" out="$2" src name head rc=0 seen=0
  mkdir -p "$out"
  for src in "$root"/skills/*/SKILL.md; do
    [ -f "$src" ] || continue
    name="$(basename "$(dirname "$src")")"
    if ! VIBESTACK_REPO_ROOT="$root" bash "$RENDER" "$src" "$out/$name/SKILL.md" 2>"$out/$name.err" \
      || [ ! -s "$out/$name/SKILL.md" ]; then
      echo "render failed: $name: $(head -1 "$out/$name.err" 2>/dev/null)"
      rc=1; continue
    fi
    seen=$((seen+1))
    head="$(head -c "$HEAD_BYTES" "$out/$name/SKILL.md")"
    if ! grep -qF -- "$LINE1" <<<"$head" || ! grep -qF -- "$LINE2" <<<"$head"; then
      echo "missing re-anchor note in first $HEAD_BYTES B: $name"
      rc=1
    fi
  done
  if [ "$seen" -eq 0 ] && [ "$rc" -eq 0 ]; then
    echo "no rendered skills under $root/skills"
    return 1
  fi
  return "$rc"
}

# mkskill <tree> <name> <pad-bytes> [with-note] — a SKILL.md with frontmatter,
# <pad-bytes> of filler, and the note placed before the filler when asked.
mkskill() {
  mkdir -p "$1/skills/$2" "$1/lib/snippets"
  {
    printf -- '---\nname: %s\ndescription: demo\n---\n\n' "$2"
    [ "${4:-}" = with-note ] && printf '%s\n%s\n\n' "$LINE1" "$LINE2"
    python3 -I -c 'import sys; n = int(sys.argv[1]); sys.stdout.write(("x" * 99 + "\n") * (n // 100))' "$3"
  } > "$1/skills/$2/SKILL.md"
}

echo "== fixtures =="

t="$TMP/good"; mkskill "$t" good 50000 with-note
out=$(check_tree "$t" "$TMP/out-good"); rc=$?
[ "$rc" -eq 0 ] && ok "a large skill with the note at its head passes" || no "note at the head failed (rc=$rc): $out"

t="$TMP/none"; mkskill "$t" good 2000 with-note; mkskill "$t" bare 2000
out=$(check_tree "$t" "$TMP/out-none"); rc=$?
[ "$rc" -eq 1 ] && grep -q "missing re-anchor note in first $HEAD_BYTES B: bare" <<<"$out" \
  && ! grep -q ": good$" <<<"$out" \
  && ok "a skill without the note fails and is named" || no "missing note passed (rc=$rc): $out"

t="$TMP/late"; mkskill "$t" late $((HEAD_BYTES + 1000))
printf '%s\n%s\n' "$LINE1" "$LINE2" >> "$t/skills/late/SKILL.md"
out=$(check_tree "$t" "$TMP/out-late"); rc=$?
[ "$rc" -eq 1 ] && grep -q "missing re-anchor note in first $HEAD_BYTES B: late" <<<"$out" \
  && ok "a note past the first $HEAD_BYTES B fails" || no "late note passed (rc=$rc): $out"

t="$TMP/half"; mkskill "$t" half 2000
printf '%s\n' "$LINE1" >> "$t/skills/half/SKILL.md"
out=$(check_tree "$t" "$TMP/out-half"); rc=$?
[ "$rc" -eq 1 ] && grep -q "missing re-anchor note in first $HEAD_BYTES B: half" <<<"$out" \
  && ok "half of the note fails" || no "half note passed (rc=$rc): $out"

t="$TMP/broken"; mkskill "$t" demo 2000 with-note
printf '{{include lib/snippets/missing.md}}\n' >> "$t/skills/demo/SKILL.md"
out=$(check_tree "$t" "$TMP/out-broken"); rc=$?
[ "$rc" -eq 1 ] && grep -q "render failed: demo" <<<"$out" \
  && ok "a skill that fails to render fails the guard" || no "render error passed (rc=$rc): $out"

mkdir -p "$TMP/empty/skills"
out=$(check_tree "$TMP/empty" "$TMP/out-empty"); rc=$?
[ "$rc" -eq 1 ] && ok "a tree with no skills fails the guard" || no "empty tree passed (rc=$rc): $out"

echo
echo "== $TREE =="
if out=$(check_tree "$TREE" "$TMP/out-tree"); then
  ok "every rendered skill carries the re-anchor note in its first $HEAD_BYTES B"
else
  echo "$out"
  no "re-anchor note guard"
fi

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
