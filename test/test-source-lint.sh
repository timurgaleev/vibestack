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

# 9. positionals: the host replaces $N (N digits, no word character after) with
#    the Nth argument before the model reads the skill, fenced or in prose: an
#    error everywhere.
d=$(mkfix posawk); printf '# demo\n```bash\nawk %s{print $1}%s f\n```\n' "'" "'" > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'SKILL.md:3: bare \$1 ' <<<"$out" && ok "bare \$1 in an awk fence fails with file:line" || no "fenced \$1 missed (rc=$rc): $out"

d=$(mkfix posesc); printf '# demo\n```sh\nsh -c "echo \\$2"\n```\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'SKILL.md:3: bare \$2 ' <<<"$out" && ok "a backslash before \$2 does not protect it" || no "escaped \$2 missed (rc=$rc): $out"

d=$(mkfix postext); printf '# demo\n```\nEst. cost: ~$0.12\n```\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'SKILL.md:3: bare \$0 ' <<<"$out" && ok "any fence is checked, not only shell fences" || no "\$0 in a plain fence missed (rc=$rc): $out"

d=$(mkfix possnip); printf '# snip\n```bash\nSTATE=$(printf x | awk %s{print $1}%s)\n```\n' "'" "'" > "$d/lib/snippets/st.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'st.md:3: bare \$1 ' <<<"$out" && ok "snippets are checked for positionals" || no "snippet positional missed (rc=$rc): $out"

d=$(mkfix posok); printf '# demo\n```bash\nf() { x=${1}; shift; }\nawk %s{print $(1); n = $NF}%s f\necho "$# $@ $$ $1x $10a"\n```\n' "'" "'" > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'positional\|bare \$' <<<"$out" && ok "\${1}, \$(1), \$NF and \$1x pass" || no "safe forms flagged (rc=$rc): $out"

d=$(mkfix posprose); printf '# demo\n\nA service up more than $500 is HIGH.\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '^[^w].*SKILL.md:3: bare \$500 ' <<<"$out" && ok "a prose positional is a finding" || no "prose positional (rc=$rc): $out"

# 10. pyisolate: a fenced python3 -c / python3 - without -I imports from the
#     current directory first — a finding.
d=$(mkfix pyc); printf '# demo\n```bash\npython3 -c "print(1)"\npython3 - <<EOF\nEOF\npython3 -I -c "print(1)"\npython3 -Ic "print(1)"\npython3 -I - x <<EOF\nEOF\npython3 script.py\n```\n\nRun python3 -c in prose.\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "python3 without -I fails the lint" || no "python3 without -I did not fail the lint (rc=$rc)"
grep -q '^[^w].*SKILL.md:3: python3 -c without -I' <<<"$out" && grep -q '^[^w].*SKILL.md:4: python3 - without -I' <<<"$out" \
  && ok "python3 -c and python3 - without -I are findings with file:line" || no "unisolated python not reported as a finding: $out"
[ "$(grep -c 'without -I' <<<"$out")" -eq 2 ] && ok "-I, -Ic, a script path and prose are not flagged" || no "isolated python flagged: $out"
d=$(mkfix pyok); printf '# demo\n```bash\npython3 -I -c "print(1)"\npython3 -I - <<EOF\nEOF\n```\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "isolated python3 lints clean" || no "isolated python3 failed the lint (rc=$rc): $out"

# 11. hostpath: a file read through a Claude Code install path resolves on no
#     other host — a finding, with or without --strict.
d=$(mkfix hostpath); printf '%s\n' '# demo' \
  'Read `~/.claude/skills/review/checklist.md`.' \
  '```bash' 'cat ~/.claude/skills/review/specialists/testing.md' '```' \
  '**Read `.claude/skills/review/design-checklist.md`.**' \
  'Copy `qa/templates/qa-report-template.md` and see (qa/references/issue-taxonomy.md).' \
  'Follow `review/TODOS-format.md`.' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "a hostpath fails the lint without --strict" || no "hostpath did not fail the lint (rc=$rc): $out"
for n in 2 4 6 7 8; do
  grep -q "^[^w].*SKILL.md:$n: hard-coded host path" <<<"$out" \
    && ok "hostpath form on line $n is a finding with file:line" || no "hostpath line $n not reported as a finding: $out"
done
[ "$(grep -c 'hard-coded host path' <<<"$out")" -eq 5 ] && ok "one hostpath finding per line" || no "hostpath finding count: $out"
out=$(bash "$LINT" --strict "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '^[^w].*SKILL.md:6: hard-coded host path' <<<"$out" \
  && ok "--strict keeps a hostpath a finding" || no "--strict did not fail on hostpath (rc=$rc): $out"

d=$(mkfix hostpathok); printf '%s\n' '# demo' \
  'Read `${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/demo}/checklist.md`.' \
  'Read `${CLAUDE_SKILL_DIR}/../review/TODOS-format.md` and `skills/qa/templates/x.md`.' \
  'A global `~/.claude/skills/` directory, or one parked at `~/.claude/skills/vibestack`.' \
  'Tell the model to ignore `.claude/skills/` entirely.' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" --strict "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'host path' <<<"$out" \
  && ok "braced fallback, sibling path and directory mentions pass --strict" || no "safe hostpath forms flagged (rc=$rc): $out"

d=$(mkfix hostpathsnip); printf '# snip\n\nRead `~/.claude/skills/review/checklist.md`.\n' > "$d/lib/snippets/hp.md"
out=$(bash "$LINT" "$d" 2>&1)
grep -q '^[^w].*hp.md:3: hard-coded host path' <<<"$out" && ok "snippets are checked for host paths" || no "snippet host path missed: $out"

# 12. --strict fails closed: a run that checked nothing is never "clean".
out=$(bash "$LINT" --strict "$TMP/no-such-root" 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -q 'no skills/ directory' <<<"$out" \
  && ok "--strict on a missing root exits 2" || no "missing root passed (rc=$rc): $out"
out=$(bash "$LINT" strict 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a mistyped --strict read as the root exits 2" || no "mistyped flag passed (rc=$rc): $out"
d="$TMP/emptytree"; mkdir -p "$d/skills" "$d/lib/snippets"
out=$(bash "$LINT" --strict "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'no skill or snippet files to check' <<<"$out" \
  && ok "--strict on a tree with no skill or snippet files fails" || no "empty tree passed --strict (rc=$rc): $out"
d=$(mkfix unreadable); chmod 000 "$d/skills/demo/SKILL.md"
if [ -r "$d/skills/demo/SKILL.md" ]; then
  ok "unreadable-file case skipped (running as a user who can read mode 000)"
else
  out=$(bash "$LINT" --strict "$d" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && grep -q 'SKILL.md: unreadable' <<<"$out" \
    && ok "--strict fails on an unreadable skill file" || no "unreadable file passed --strict (rc=$rc): $out"
fi
chmod 644 "$d/skills/demo/SKILL.md"
d=$(mkfix awkfail); mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\nexit 2\n' > "$TMP/fakebin/awk"; chmod +x "$TMP/fakebin/awk"
out=$(PATH="$TMP/fakebin:$PATH" bash "$LINT" --strict "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'awk exited 2' <<<"$out" \
  && ok "--strict fails when awk fails" || no "awk failure passed --strict (rc=$rc): $out"

# 13. Every awk pass fails closed: an awk that dies in the fence, snippet,
#     hostvars or positional pass is a finding, never a clean run.
cat > "$TMP/fakebin/awk" <<EOF
#!/bin/sh
case "\$*" in *"\$LINT_FAIL_MARK"*) echo "awk: forced failure" >&2; exit 2 ;; esac
exec "$(command -v awk)" "\$@"
EOF
chmod +x "$TMP/fakebin/awk"
awkn=0
for mark in 'END { if (fc != "")' 'include lib' 'seen[$0]++' 'function flush(' 'function positional('; do
  d=$(mkfix "awkpass$((++awkn))")
  printf '# snip\n\nbody\n' > "$d/lib/snippets/good.md"
  out=$(LINT_FAIL_MARK="$mark" PATH="$TMP/fakebin:$PATH" bash "$LINT" "$d" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && grep -q 'awk exited 2' <<<"$out" \
    && ok "an awk failure in the pass holding '$mark' fails the lint" || no "awk failure in '$mark' pass passed (rc=$rc): $out"
done

# 14. Bytes, not characters: under a UTF-8 locale BSD awk aborts on a split or
#     invalid multibyte sequence. The lint must still read the whole line.
d=$(mkfix utf8); printf '# demo\n```bash\nx="\342\200" y=$1 \303\251\n```\n' > "$d/skills/demo/SKILL.md"
out=$(LC_ALL=en_US.UTF-8 bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'SKILL.md:3: bare \$1' <<<"$out" \
  && ok "an invalid UTF-8 byte does not hide a positional on the same line" || no "invalid UTF-8 line not linted (rc=$rc): $out"

# 15. A fence inside a list item may sit 4+ spaces in (relative to the item's
#     content it is 0-3): it is a fence for balance and for the fenced rules.
d=$(mkfix listfence); printf '%s\n' '# demo' '- **If GitHub:**' '    ```bash' '    python3 -c "print(1)"' '    ```' \
  '1. Step' '   - sub' '     ```' '     unclosed' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'SKILL.md:4: python3 -c without -I' <<<"$out" \
  && ok "python3 -c in a list-item fence indented 4 spaces is a finding" || no "list-item fence not treated as a fence (rc=$rc): $out"
grep -q 'SKILL.md:8: unclosed fence opened here' <<<"$out" \
  && ok "an unclosed list-item fence indented 5 spaces is caught" || no "unclosed list-item fence missed: $out"
d=$(mkfix listcode); printf '%s\n' '# demo' '- item' '' '      ```' '      not a fence: indented code inside the item' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a fence line 4+ past the item's content column is indented code" || no "indented code in a list item flagged (rc=$rc): $out"

# 16. Skill sub-docs (skills/<name>/**/*.md besides SKILL.md) are read by the
#     model too: fences, host paths and python isolation apply. The host does
#     not substitute $N in them, so positionals do not.
d=$(mkfix subdoc); mkdir -p "$d/skills/demo/specialists"
printf '%s\n' '# ref' 'Read `~/.claude/skills/review/checklist.md`.' '```bash' 'python3 -c "print(1)"' 'awk '"'"'{print $1}'"'"' f' '```' > "$d/skills/demo/specialists/ref.md"
printf '# t\n```\nunclosed\n' > "$d/skills/demo/notes.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'specialists/ref.md:2: hard-coded host path' <<<"$out" \
  && ok "a sub-doc host path is a finding" || no "sub-doc host path missed (rc=$rc): $out"
grep -q 'specialists/ref.md:4: python3 -c without -I' <<<"$out" && ok "a sub-doc python3 -c is a finding" || no "sub-doc python missed: $out"
grep -q 'notes.md:2: unclosed fence' <<<"$out" && ok "a sub-doc unclosed fence is a finding" || no "sub-doc fence missed: $out"
grep -q 'ref.md:5: bare' <<<"$out" && no "a sub-doc positional was flagged: $out" || ok "positionals are not checked in sub-docs"

# 17. Every positional is a finding, prose and inline code included, and each
#     one on a line is named.
d=$(mkfix posall); printf '# demo\n\nPass `$1` and $2 through.\n' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '^[^w].*SKILL.md:3: bare \$1, \$2 ' <<<"$out" \
  && ok "prose positionals are findings, all of them named" || no "prose positionals (rc=$rc): $out"

# 18. pyisolate covers every inline-code shape: options that take a separate
#     argument, versioned and absolute interpreters, a continued line, stdin
#     with no "-", and -m.
d=$(mkfix pygaps); printf '%s\n' '# demo' '```bash' \
  'python3 -W ignore -c "x"' 'python3 -X utf8 -c "x"' 'python -c "x"' 'python3.12 -c "x"' \
  '/usr/bin/python3 -c "x"' 'out=$(python3 \' '  -c "x")' "python3 <<'PY'" 'PY' 'python3 -m json.tool f' \
  'python3 -W ignore -I -c "x"' 'python3 -X utf8 script.py' 'command -v python3 >/dev/null' 'python3 --version' \
  'printf x | python3 -I' '```' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
got=$(grep 'without -I' <<<"$out" | sed -E 's/.*SKILL\.md:([0-9]+):.*/\1/' | tr '\n' ' ')
[ "$rc" -eq 1 ] && [ "$got" = "3 4 5 6 7 8 10 12 " ] \
  && ok "every unisolated python shape is a finding and isolated ones are not" || no "pyisolate shapes: got '$got' (rc=$rc): $out"

# 19. ./install runs the lint before rendering: it shows findings and stops on
#     them, but never prints authoring warnings the person installing cannot act on.
H="$TMP/insthome"; mkdir -p "$H"
out=$(HOME="$H" VIBESTACK_HOME="$H/.vibestack" bash "$ROOT/install" --dry-run --target=claude --no-config 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^warn: ' <<<"$out" \
  && ok "install prints no lint warnings" || no "install printed lint warnings (rc=$rc): $(grep -m2 '^warn: ' <<<"$out")"
INST="$TMP/insttree"; mkdir -p "$INST"
cp -R "$ROOT/install" "$ROOT/bin" "$ROOT/lib" "$INST/" 2>/dev/null; mkdir -p "$INST/skills/demo"
printf '# demo\n```\nunclosed\n' > "$INST/skills/demo/SKILL.md"
out=$(HOME="$H" VIBESTACK_HOME="$H/.vibestack" bash "$INST/install" --dry-run --target=claude --no-config 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'SKILL.md:2: unclosed fence' <<<"$out" && grep -q 'source lint failed' <<<"$out" \
  && ok "install shows a lint finding and stops" || no "install lint finding (rc=$rc): $out"

# 20. hostpath reads $HOME and ${HOME} spellings of the install path too, and
#     passes the shapes that name no file: a :- fallback, a glob or <name>
#     placeholder over every installed skill, a directory with a trailing slash.
d=$(mkfix hostpathhome); printf '%s\n' '# demo' 'cat "$HOME/.claude/skills/review/checklist.md"' \
  'Read `${HOME}/.claude/skills/qa/x.md`.' 'cat .claude/skills/review/checklist.md' 'Open ./.claude/skills/qa/x.md first.' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'SKILL.md:2: hard-coded host path' <<<"$out" && grep -q 'SKILL.md:3: hard-coded host path' <<<"$out" \
  && ok "\$HOME and \${HOME} install paths are findings" || no "\$HOME install paths missed (rc=$rc): $out"
grep -q 'SKILL.md:4: hard-coded host path' <<<"$out" && grep -q 'SKILL.md:5: hard-coded host path' <<<"$out" \
  && ok "a repo-relative .claude/skills/<name>/<file>, with or without ./, is a finding" || no "repo-relative install path missed: $out"
d=$(mkfix hostpathshapes); printf '%s\n' '# demo' 'D="${CLAUDE_SKILL_DIR:-~/.claude/skills/demo}/x.md"' \
  'ls ~/.claude/skills/*/SKILL.md' 'Each skill lives at `~/.claude/skills/<name>/SKILL.md`.' \
  'The pack installs into `~/.claude/skills/demo/`.' > "$d/skills/demo/SKILL.md"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a :- fallback, a glob, a <name> placeholder and a directory mention pass" || no "harmless install-path shapes flagged (rc=$rc): $out"

# 21. An unknown flag is a usage error.
out=$(bash "$LINT" --bogus 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -q '^usage:' <<<"$out" && ok "an unknown flag exits 2 with usage" || no "unknown flag (rc=$rc): $out"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
