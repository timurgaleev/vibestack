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
[ "$rc" -eq 1 ] && grep -q "SKILL.md:2: unclosed fence opened here" <<<"$out" && ok "unbalanced fence caught" || no "fence rule missed (rc=$rc)"

# 2b. Fence shapes. fence_case <name> <expect: pass|fail> <printf body>
fence_case() {
  local d; d=$(mkfix "$1"); printf "$3" > "$d/skills/demo/SKILL.md"
  out=$(bash "$LINT" "$d" 2>&1); rc=$?
  if [ "$2" = fail ]; then
    [ "$rc" -eq 1 ] && grep -q "unclosed fence opened here" <<<"$out" && ok "$4" || no "$4 (rc=$rc)"
  else
    [ "$rc" -eq 0 ] && ok "$4" || no "$4 (rc=$rc: $out)"
  fi
}
fence_case indentfence fail '# demo\n   ```bash\nunclosed\n' "unclosed 3-space-indented fence caught"
fence_case tildefence fail '# demo\n~~~\nunclosed\n' "unclosed ~~~ fence caught"
fence_case longfence pass '# demo\n````md\n```bash\nx\n```\n````\n' "4-backtick block holding \`\`\` lines passes"
fence_case tildeholds pass '# demo\n~~~\n```\nx\n~~~\n' "~~~ block holding a \`\`\` line passes"
fence_case wrongchar fail '# demo\n```\nx\n~~~\n' "a closer of the other character does not close"
fence_case deepindent pass '# demo\n    ```\ncode\n' "a 4-space-indented fence line is content"
fence_case backtickinfo pass '# demo\n``` `x` ```\ntext\n' "a backtick run whose info string holds a backtick is not a fence"
fence_case tildeinfo fail '# demo\n~~~ `x`\nunclosed\n' "a ~~~ opener may carry a backtick in its info string"

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

# 8. hostvars: a host-only variable inside a bash fence warns without failing;
#    the same token in prose does not warn.
d=$(mkfix hostvar); printf '# demo\n\nPass $ARGUMENTS through.\n\n```bash\necho "$ARGUMENTS"\n```\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "hostvars warning does not fail the lint" || no "hostvars warning failed the lint (rc=$rc)"
grep -q 'warn: .*SKILL.md:6: \$ARGUMENTS is substituted only by Claude Code' <<<"$out" \
  && ok "\$ARGUMENTS in a bash fence warns with file:line" || no "\$ARGUMENTS in a fence not warned: $out"
[ "$(grep -c '^warn:' <<<"$out")" -eq 1 ] && ok "prose mention does not warn" || no "prose mention warned: $out"

d=$(mkfix skilldir); printf '# demo\n```bash\nbash "${CLAUDE_SKILL_DIR}/bin/x.sh"\n```\n```bash\nD="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/demo}"\n```\n```sh\ncommand -v x >/dev/null || bash "${CLAUDE_SKILL_DIR}/bin/x.sh"\n```\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'warn: .*SKILL.md:3: \${CLAUDE_SKILL_DIR} is substituted only by Claude Code' <<<"$out" \
  && ok "bare \${CLAUDE_SKILL_DIR} in a fence warns" || no "bare CLAUDE_SKILL_DIR not warned (rc=$rc): $out"
[ "$(grep -c '^warn:' <<<"$out")" -eq 1 ] && ok "a :- default or command -v fallback in the block does not warn" \
  || no "guarded CLAUDE_SKILL_DIR warned: $out"

d=$(mkfix hostsnip); printf '# snip\n~~~sh\nset -- $ARGUMENTS\n~~~\n' > "$d/lib/snippets/args.md"
out=$(bash "$LINT" "$d" 2>&1)
grep -q 'warn: .*args.md:3: \$ARGUMENTS' <<<"$out" && ok "snippets are checked too" || no "snippet not checked: $out"

d=$(mkfix hostother); printf '# demo\n```text\n$ARGUMENTS\n```\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1)
grep -q '^warn:' <<<"$out" && no "non-shell fence warned: $out" || ok "non-shell fence does not warn"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
