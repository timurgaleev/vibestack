#!/usr/bin/env bash
# Tests for bin/vibe-lint-sources: real tree must be clean; synthetic trees
# must trip each rule with a file:line finding.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$ROOT/bin/vibe-lint-sources"
TMP="$(mktemp -d)"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

# 1. The real repo lints clean.
if bash "$LINT" "$ROOT" >/dev/null 2>&1; then ok "real tree clean"; else no "real tree has lint findings"; fi

mkfix() { # mkfix <name> → builds $TMP/<name>/{skills/demo,lib/snippets}
  local d="$TMP/$1"
  mkdir -p "$d/skills/demo" "$d/lib/snippets"
  printf '# demo\n\nbody\n' > "$d/skills/demo/SKILL.md"
  printf '# snip\n\nbody\n' > "$d/lib/snippets/good.md"
  echo "$d"
}

# 2. Unbalanced fence in a skill source.
d=$(mkfix fence); printf '# demo\n```\nunclosed\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q "odd number" <<<"$out" && ok "unbalanced fence caught" || no "fence rule missed (rc=$rc)"

# 3. Nested include in a snippet.
d=$(mkfix nested); printf '# snip\n{{include lib/snippets/other.md}}\n' > "$d/lib/snippets/bad.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q "nested {{include}}" <<<"$out" && ok "nested include caught" || no "nested include missed (rc=$rc)"

# 4. Indented include directive is content, not a directive — must pass.
d=$(mkfix indented); printf '# snip\n    {{include lib/snippets/other.md}}\n' > "$d/lib/snippets/doc.md"
bash "$LINT" "$d" >/dev/null 2>&1 && ok "indented directive not flagged" || no "indented directive false positive"

# 4b. Fenced include directive is documentation, not a directive — must pass.
d=$(mkfix fencedinc); printf '# snip\n```\n{{include lib/snippets/other.md}}\n```\n' > "$d/lib/snippets/doc.md"
bash "$LINT" "$d" >/dev/null 2>&1 && ok "fenced directive not flagged" || no "fenced directive false positive"

# 5. Duplicate heading in a snippet.
d=$(mkfix dup); printf '## Same\nbody\n## Same\n' > "$d/lib/snippets/dup.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q "duplicate heading" <<<"$out" && ok "duplicate heading caught" || no "duplicate heading missed (rc=$rc)"

# 6. Duplicate heading inside a fenced block is content — must pass.
d=$(mkfix fencedup); printf '## A\n```\n## B\n## B\n```\n' > "$d/lib/snippets/fenced.md"
bash "$LINT" "$d" >/dev/null 2>&1 && ok "fenced duplicate not flagged" || no "fenced duplicate false positive"

# 7. Oversized snippet.
d=$(mkfix big); { echo '# big'; for i in $(seq 1 401); do echo "line $i"; done; } > "$d/lib/snippets/big.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q "max 400" <<<"$out" && ok "oversized snippet caught" || no "size rule missed (rc=$rc)"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
