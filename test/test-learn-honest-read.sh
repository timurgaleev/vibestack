#!/usr/bin/env bash
# /learn and the prior-learnings snippet: a failed learnings read must surface as
# "LEARNINGS: unavailable (...)", never as an empty shelf, and --cross-project
# must carry only trusted (user-stated) entries between projects, end to end
# through vibe-learnings-log.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
SKILL="$ROOT/skills/learn/SKILL.md"
SNIP="$ROOT/lib/snippets/prior-learnings.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VIBESTACK_HOME="$TMP/home"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# 1. No call site discards the search's stderr or turns a failure into silence.
for f in "$SKILL" "$SNIP"; do
  name="${f#"$ROOT"/}"
  if grep -nE 'vibe-learnings-search.*(2>/dev/null|\|\|[[:space:]]*true|No learnings yet\.|No matches\.)' "$f"; then
    no "$name swallows a failed learnings read"
  else
    ok "$name keeps search failures visible"
  fi
  n_calls=$(grep -c '/bin/vibe-learnings-search ' "$f")
  n_honest=$(grep -c 'LEARNINGS: unavailable (vibe-learnings-search exited \$?)' "$f")
  [ "$n_calls" -gt 0 ] && [ "$n_calls" -eq "$n_honest" ] \
    && ok "$name: every search ($n_calls) reports unavailable on failure" \
    || no "$name: $n_calls searches, $n_honest with an unavailable fallback"
done
grep -q -- '--cross-project' "$SNIP" && ok "snippet passes --cross-project when enabled" \
  || no "snippet never passes --cross-project"

# 2. Run the /learn Pass 1 block against a search that fails: the output must
#    say unavailable, not "No learnings yet".
STUB="$TMP/stub/.vibestack/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho SLUG=stubproj\n' > "$STUB/vibe-slug"
printf '#!/usr/bin/env bash\necho "cannot read store" >&2\nexit 1\n' > "$STUB/vibe-learnings-search"
chmod +x "$STUB/vibe-slug" "$STUB/vibe-learnings-search"
BLOCK="$TMP/pass1.sh"
awk '/^\*\*Pass 1/{p=1} p&&/^```bash$/{c=1;next} c&&/^```$/{exit} c{print}' "$SKILL" > "$BLOCK"
if [ -s "$BLOCK" ]; then
  out="$(HOME="$TMP/stub" VIBESTACK_HOME="$TMP/stub/.vibestack" bash "$BLOCK" 2>&1)"
  echo "$out" | grep -q 'LEARNINGS: unavailable (vibe-learnings-search exited 1)' \
    && ok "Pass 1 reports a failed read as unavailable" || no "Pass 1 failure output: '$out'"
  echo "$out" | grep -q 'No learnings yet' && no "Pass 1 calls a failed read empty" || ok "Pass 1 does not call a failed read empty"
else
  no "could not extract the Pass 1 block"
fi

# 3. The search itself: no python3 -> non-zero exit with a reason.
NOPY="$TMP/nopy"; mkdir -p "$NOPY" "$TMP/w/projalpha"
for t in bash dirname basename git sed awk tr echo cat cut shasum sha256sum; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOPY/$t"
done
# Without a remote the bucket is the folder name plus a hash of the path.
ALPHA="$(cd "$TMP/w/projalpha" && "$BIN/vibe-slug" 2>/dev/null | sed -n 's/^SLUG=//p')"
mkdir -p "$VIBESTACK_HOME/projects/$ALPHA"
echo '{"type":"pattern","key":"k","insight":"i","confidence":5,"source":"observed"}' \
  > "$VIBESTACK_HOME/projects/$ALPHA/learnings.jsonl"
out="$(cd "$TMP/w/projalpha" && PATH="$NOPY" "$NOPY/bash" "$BIN/vibe-learnings-search" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'python3 not found' \
  && ok "missing python3 exits non-zero with a reason" || no "missing python3: rc=$rc '$out'"
rm -f "$VIBESTACK_HOME/projects/$ALPHA/learnings.jsonl"

# 4. Cross-project end to end: log in one project, search from another.
mkdir -p "$TMP/w/projbeta"
(cd "$TMP/w/projalpha" && "$BIN/vibe-learnings-log" \
  '{"skill":"learn","type":"preference","key":"said-outright","insight":"tabs over spaces mango","confidence":9,"source":"user-stated"}') >/dev/null \
  || no "logging a user-stated entry failed"
(cd "$TMP/w/projalpha" && "$BIN/vibe-learnings-log" \
  '{"skill":"learn","type":"pattern","key":"guessed","insight":"mango guess from code","confidence":9,"source":"inferred","trusted":true}') >/dev/null \
  || no "logging an inferred entry failed"
grep -q '"key":"said-outright".*"trusted":true' "$VIBESTACK_HOME/projects/$ALPHA/learnings.jsonl" \
  && ok "log marks a user-stated entry trusted" || no "user-stated entry not marked trusted"
grep -q '"key":"guessed".*"trusted":false' "$VIBESTACK_HOME/projects/$ALPHA/learnings.jsonl" \
  && ok "log ignores a payload's own trusted claim" || no "inferred entry kept a caller-supplied trusted flag"

out="$(cd "$TMP/w/projbeta" && "$BIN/vibe-learnings-search" --query mango 2>&1)"
echo "$out" | grep -q 'said-outright' && no "another project's entry shown without --cross-project" \
  || ok "search stays project-scoped by default"
out="$(cd "$TMP/w/projbeta" && "$BIN/vibe-learnings-search" --query mango --cross-project 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'said-outright.*cross-project: projalpha' \
  && ok "--cross-project brings the trusted entry over, tagged" || no "--cross-project: rc=$rc '$out'"
echo "$out" | grep -q 'guessed' && no "untrusted entry crossed projects" || ok "untrusted entry stays in its project"

echo
echo "test-learn-honest-read: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
