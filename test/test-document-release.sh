#!/usr/bin/env bash
# test-document-release.sh — /document-release behaves when another agent runs
# it, and its shell blocks survive hostile PR text and fresh-shell tool calls.
#
# The blocks under test are extracted from the rendered skill and executed
# against stub `gh`/`glab` binaries in throwaway repos, so a regression in the
# skill text turns this red without a live hosting account.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/skills/document-release/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SKILL="$TMP/SKILL.md"
"$ROOT/bin/vibe-render-skill" "$SRC" "$SKILL" >/dev/null

# fenced FILE START_REGEX -> body of the first ```bash block whose first line
# matches START_REGEX
fenced() {
  awk -v re="$2" '
    /^```bash$/ { inb=1; first=1; buf=""; next }
    /^```$/ && inb { if (hit) { printf "%s", buf; exit } inb=0; next }
    inb { if (first && $0 ~ re) hit=1; first=0; buf = buf $0 "\n" }
  ' "$1"
}

echo "session kind"
SK="$ROOT/bin/vibe-session-kind"
[ "$(env -u CI -u VIBESTACK_HEADLESS -u OPENCLAW_SESSION VIBE_SPAWNED=1 "$SK")" = spawned ] \
  && ok "VIBE_SPAWNED=1 marks a spawned session" || no "VIBE_SPAWNED=1 not spawned"
[ "$(env -u CI -u VIBESTACK_HEADLESS -u OPENCLAW_SESSION VIBE_SPAWNED=0 "$SK")" = interactive ] \
  && ok "VIBE_SPAWNED=0 is not spawned" || no "VIBE_SPAWNED=0 read as spawned"
[ "$(env -u VIBESTACK_HEADLESS -u OPENCLAW_SESSION CI=true VIBE_SPAWNED=1 "$SK")" = spawned ] \
  && ok "spawned wins over CI" || no "CI hid a spawned session"

echo "spawned contract"
grep -q '^## Spawned mode' "$SKILL" && ok "spawned section present" || no "no spawned section"
grep -q 'export VIBE_SPAWNED=1' "$SKILL" && ok "dispatcher marking documented" || no "marking not documented"
json=$(grep -E '^\{"schema_version":1,' "$SKILL" | head -1)
if [ -n "$json" ] && printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
need = {"schema_version","status","files_updated","files_reviewed","blockers","decisions","documentation_section"}
assert need <= set(d), need - set(d)
assert d["status"] in ("updated", "current", "blocked")
'; then ok "result example parses with every contract field"; else no "result example missing or invalid"; fi
sec=$(sed -n '/^## Spawned mode/,/^## Step 1:/p' "$SKILL")
for s in '"status":"blocked"' 'Steps 5, 7, 8, 8.5 and 9 do not run' 'git commit' 'AskUserQuestion'; do
  printf '%s' "$sec" | grep -qF "$s" && ok "spawned section names: $s" || no "spawned section lacks: $s"
done

echo "doc discovery"
DISC=$(fenced "$SKILL" '^git ls-files -z --cached --others')
[ -n "$DISC" ] && ok "discovery block found" || no "discovery block missing"
R1="$TMP/repo1"; mkdir -p "$R1/skills/demo" "$R1/docs/guide/deep" "$R1/node_modules/pkg"
git -C "$R1" init -q
printf 'x\n' > "$R1/README.md"; printf 'x\n' > "$R1/skills/demo/SKILL.md"
printf 'x\n' > "$R1/docs/guide/deep/page.mdx"; printf 'x\n' > "$R1/docs/api.rst"
printf 'x\n' > "$R1/node_modules/pkg/README.md"
found=$(cd "$R1" && bash -c "$DISC")
for f in README.md skills/demo/SKILL.md docs/guide/deep/page.mdx docs/api.rst; do
  printf '%s\n' "$found" | grep -qx "$f" && ok "discovers $f" || no "misses $f"
done
printf '%s\n' "$found" | grep -q node_modules && no "lists node_modules" || ok "skips node_modules"
grep -q 'config/codex/AGENTS.md' "$SKILL" && ok "generated AGENTS.md is named" || no "generated-doc rule missing"

echo "codex doc review"
step85=$(sed -n '/^## Step 8.5/,/^## Step 9/p' "$SKILL")
printf '%s' "$step85" | grep -q 'codex exec "' && no "prompt still spliced into argv" || ok "no prompt in argv"
printf '%s' "$step85" | grep -q 'codex exec - .*< "\$_PROMPT_FILE"' && ok "prompt goes in on stdin" || no "prompt not on stdin"
printf '%s' "$step85" | grep -q 'vibe-codex-probe' && ok "preflight uses the probe" || no "preflight skips the probe"
printf '%s' "$step85" | grep -q '! codex --version' && no "--version still decides auth" || ok "--version no longer decides auth"
for s in '"unavailable"' '"disabled"' 'Write the' 'run_in_background: false'; do
  printf '%s' "$step85" | grep -qF "$s" && ok "review step has: $s" || no "review step lacks: $s"
done

echo "pr body"
grep -q '/tmp/vibestack-pr-body' "$SKILL" && no "fixed /tmp body path remains" || ok "no fixed /tmp body path"
grep -q 'mktemp -d "${TMPDIR:-/tmp}/vibe-doc-release-' "$SKILL" && ok "private run dir" || no "no private run dir"
grep -q "<<'MRBODY'" "$SKILL" && no "MR body still pasted into a heredoc" || ok "no MR body heredoc"
WB=$(grep -E "^python3 -c 'import pathlib,subprocess,sys; subprocess.run\(\[\"glab\"" "$SKILL" | head -1)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/glab" <<'STUB'
#!/usr/bin/env bash
# records the -d argument verbatim
while [ $# -gt 0 ]; do [ "$1" = -d ] && { printf '%s' "$2" > "$STUB_OUT"; shift; }; shift; done
STUB
chmod +x "$TMP/bin/glab"
RUN="$TMP/run"; mkdir -p "$RUN"
printf 'intro\nMRBODY\n$(touch %s/pwned) `id` "quote\n' "$TMP" > "$RUN/body.md"
if [ -n "$WB" ]; then
  cmd=${WB//<run-dir>/$RUN}
  PATH="$TMP/bin:$PATH" STUB_OUT="$TMP/sent" bash -c "$cmd"
  cmp -s "$RUN/body.md" "$TMP/sent" && ok "GitLab write-back sends the body byte-exact" || no "GitLab body altered"
  [ ! -e "$TMP/pwned" ] && ok "body text never executes" || no "body text executed"
else
  no "GitLab write-back line missing"
fi

echo "title sync"
TS=$(fenced "$SKILL" '^V=.*tr -d')
[ -n "$TS" ] && ok "title sync is one block" || no "title sync block missing"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s\n' "$STUB_TITLE" ;;
  "pr edit") printf '%s' "$4" > "$STUB_OUT" ;;
esac
STUB
chmod +x "$TMP/bin/gh"
title() {  # version title expected label
  local d="$TMP/t.$RANDOM"; mkdir -p "$d"; rm -f "$TMP/edited"
  [ -n "$1" ] && printf '%s\n' "$1" > "$d/VERSION"
  (cd "$d" && PATH="$TMP/bin:$PATH" STUB_TITLE="$2" STUB_OUT="$TMP/edited" bash -c "${TS//<platform>/github}") >/dev/null 2>&1
  local got; got=$(cat "$TMP/edited" 2>/dev/null || echo "<unchanged>")
  [ "$got" = "$3" ] && ok "title: $4" || no "title: $4 (got '$got')"
}
title 1.2.3.4 "v1.2.3.4 feat: x" "<unchanged>"        "matching prefix is left alone"
title 1.2.3.4 "v1.2.3.3 feat: x" "v1.2.3.4 feat: x"   "stale prefix is replaced"
title 1.2.3.4 "feat: x"          "v1.2.3.4 feat: x"   "missing prefix is prepended"
title 1.2.3.4 "v1x2x3x4 feat"    "v1.2.3.4 v1x2x3x4 feat" "dots in VERSION are literal"
title ""      "feat: x"          "<unchanged>"        "no VERSION skips the sync"
title 1.2.3.4 ""                 "<unchanged>"        "no PR skips the sync"

mkdir -p "$TMP/glbin"
cat > "$TMP/glbin/glab" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "mr view") [ -n "$STUB_TITLE" ] && python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1]}))' "$STUB_TITLE" ;;
  "mr update") [ "$3" = -t ] && printf '%s' "$4" > "$STUB_OUT" ;;
esac
STUB
chmod +x "$TMP/glbin/glab"
gltitle() {  # platform version title expected label
  local d="$TMP/g.$RANDOM"; mkdir -p "$d"; rm -f "$TMP/edited"
  printf '%s\n' "$2" > "$d/VERSION"
  (cd "$d" && PATH="$TMP/glbin:$PATH" STUB_TITLE="$3" STUB_OUT="$TMP/edited" bash -c "${TS//<platform>/$1}") >/dev/null 2>&1
  local got; got=$(cat "$TMP/edited" 2>/dev/null || echo "<unchanged>")
  [ "$got" = "$4" ] && ok "title: $5" || no "title: $5 (got '$got')"
}
if command -v jq >/dev/null 2>&1; then
  gltitle gitlab 1.2.3.4 "v1.2.3.3 feat: x" "v1.2.3.4 feat: x" "GitLab stale prefix is replaced"
  gltitle gitlab 1.2.3.4 "v1.2.3.4 feat: x" "<unchanged>"      "GitLab matching prefix is left alone"
  gltitle gitlab 1.2.3.4 ""                 "<unchanged>"      "GitLab without an MR skips the sync"
elif [ -n "${CI:-}" ]; then
  no "jq not installed (required under CI for the GitLab title cases)"
else
  echo "  skip jq not installed"
fi
gltitle bitbucket 1.2.3.4 "feat: x" "<unchanged>" "unknown platform skips the sync"

echo "commit and stamps"
step9=$(sed -n '/^## Step 9/,/^\*\*PR\/MR body update/p' "$SKILL")
printf '%s' "$step9" | grep -q 'still run the PR/MR body update' && ok "empty diff still reports debt and syncs title" || no "empty diff exits early"
printf '%s' "$step9" | grep -q 'pre-existing changes' && ok "pre-existing edits stay unstaged" || no "staging can sweep user edits"
sed -n '/^## Step 7/,/^## Step 8:/p' "$SKILL" | grep -q 'date-only' && ok "TODOS stamp is date-only before Step 8" || no "TODOS stamped with a version too early"
grep -q "Step 5.5" "$SKILL" && no "stale /ship step reference" || ok "no stale /ship step reference"

echo "description"
head -20 "$SKILL" | grep -q 'before the PR merges' && ok "description says before merge" || no "description says after merge"
head -20 "$SKILL" | grep -q 'docs after merge' && no "after-merge trigger remains" || ok "no after-merge trigger"

echo "sell test"
sed -n '/^## Step 5/,/^## Step 6/p' "$SKILL" | grep -qiE 'need a rewrite|flag and rewrite' \
  && no "sell test still rewrites entries" || ok "sell test flags, never rewrites"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
