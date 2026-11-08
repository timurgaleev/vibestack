#!/usr/bin/env bash
# test-improve-arch-contract.sh — contracts the /improve-arch skill text must keep.
#
# Covers:
#   - scope comes before exploration: a named direction, else a churn hotspot
#     list from git history seeds the Explore brief;
#   - every candidate carries a Strength rating and a Dependencies category,
#     and the list ends in one top recommendation asked as a decision brief;
#   - the grilling loop follows a fixed method (recommended answers, code
#     facts looked up instead of asked, a stop condition);
#   - the glossary is GLOSSARY.md before CONTEXT.md, with a context-map pick
#     and two rules for what goes in it;
#   - an ADR is offered only under three conditions and written by
#     /document-generate --adr, never by this skill;
#   - interface design frames the problem first, gives each sub-agent its own
#     constraint, and ends in a recommendation instead of refusing to pick;
#   - deepening proposes retiring shallow tests with a reason and keeps
#     contract tests, instead of deleting them outright;
#   - LANGUAGE.md carries the testability principles and the questions that
#     shrink an interface.
#
# Usage: test/test-improve-arch-contract.sh [repo-root]
set -euo pipefail

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

DIR="$SRC/skills/improve-arch"
SKILL="$TMP/improve-arch/SKILL.md"
if VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$DIR/SKILL.md" "$SKILL" >/dev/null 2>&1; then
  ok "improve-arch renders"
else
  no "improve-arch renders"; echo "$pass passed, $fail failed"; exit 1
fi

# has/hasnt take the file as the first argument so the sub-docs are checked
# in their own right, not through the rendered skill.
has()   { if grep -qF -- "$3" "$1"; then ok "$2"; else no "$2 (missing: $3)"; fi; }
# An empty section (its heading was renamed or dropped) proves nothing, so hasnt fails on it.
hasnt() {
  if [ ! -s "$1" ]; then no "$2 (nothing to check: section or file is empty)"
  elif grep -qF -- "$3" "$1"; then no "$2 (still present: $3)"; else ok "$2"; fi
}

line_of() { awk -v n="$2" 'index($0, n) { print NR; exit }' "$1"; }
before() {
  local a b
  a="$(line_of "$1" "$3")"; b="$(line_of "$1" "$4")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$2"; else no "$2 ('$3' line ${a:-none} not before '$4' line ${b:-none})"; fi
}

# Extract the body of one "### " step so a phrase elsewhere cannot satisfy it.
step() { awk -v h="$2" 'index($0, h) == 1 {f=1; next} f && /^### / {exit} f' "$1"; }

echo "scope first"
has    "$SKILL" "a scope step exists"                  '### 1. Scope first'
before "$SKILL" "scope precedes exploration"           '### 1. Scope first' '### 2. Explore'
has    "$SKILL" "churn hotspots from git history"      "--name-only --pretty=format: | grep -v '^\$' | sort | uniq -c | sort -rn | head -20"
has    "$SKILL" "a named direction wins"               'named direction'
has    "$SKILL" "hotspots seed the Explore brief"      'seed the Explore brief'

echo "candidates"
CAND="$TMP/candidates"
step "$SKILL" '### 3. Present candidates' > "$CAND"
has    "$CAND" "candidate carries Strength"            '**Strength**'
for s in 'Strong' 'Worth exploring' 'Speculative'; do
  has  "$CAND" "strength level: $s"                    "$s"
done
has    "$CAND" "candidate carries Dependencies"        '**Dependencies**'
has    "$CAND" "dependencies use DEEPENING categories" 'DEEPENING.md'
has    "$CAND" "one top recommendation"                'Top recommendation: <candidate> because <one line>'
has    "$CAND" "asked as a decision brief"             'decision brief'
has    "$CAND" "top pick marked recommended"           '(recommended)'
hasnt  "$CAND" "no bare open-ended question"           'Which of these would you like to explore?'

echo "grilling method"
GRILL="$TMP/grilling"
step "$SKILL" '### 4. Grilling loop' > "$GRILL"
has    "$GRILL" "numbered frontier"                    'numbered frontier'
has    "$GRILL" "each question carries Recommended:"   'Recommended:'
has    "$GRILL" "yes accepts the recommendation"       'a plain yes accepts it'
has    "$GRILL" "never ask what the code answers"      'Never ask what the code can answer'
has    "$GRILL" "facts come from a foreground Explore" 'run_in_background: false'
has    "$GRILL" "stated behavior is checked in code"   'Cross-check'
has    "$GRILL" "one edge case per term"               'one edge-case scenario'
has    "$GRILL" "stop condition"                       'no open decision remains'

echo "glossary"
has    "$SKILL" "GLOSSARY.md is read before CONTEXT.md" '`GLOSSARY.md` if it exists, else `CONTEXT.md`'
has    "$SKILL" "context map pick"                     'CONTEXT-MAP.md'
has    "$SKILL" "rule: domain terms only"              'a domain expert would say'
has    "$SKILL" "rule: one word per concept"           'One word per concept'

echo "adr"
ADR="$TMP/adr"
grep -F 'ADR' "$GRILL" > "$ADR" || true
has    "$ADR" "hard to reverse"                        'hard to reverse'
has    "$ADR" "surprising without context"             'surprising without context'
has    "$ADR" "a real trade-off"                       'real trade-off'
has    "$ADR" "ADR is written by document-generate"    '/document-generate --adr'

echo "interface design"
IFACE="$DIR/INTERFACE-DESIGN.md"
has    "$IFACE" "problem framed before fan-out"        '## Frame the problem first'
before "$IFACE" "framing precedes fan-out"             '## Frame the problem first' '## Sub-agent fan-out'
for c in 'Minimal surface' 'Maximal flexibility' 'Trivial common case' 'Port and adapter'; do
  has  "$IFACE" "constraint: $c"                       "**$c**"
done
has    "$IFACE" "one constraint per sub-agent"         'one constraint per sub-agent'
hasnt  "$IFACE" "no refusal to pick"                   "Don't pick"
has    "$IFACE" "ends in a recommendation"             'Recommend one shape (or a named hybrid)'

echo "deepening retention"
DEEP="$DIR/DEEPENING.md"
hasnt  "$DEEP" "shallow tests are not deleted outright" 'delete them'
has    "$DEEP" "retirement is proposed with a reason"  'propose retiring'
has    "$DEEP" "contract tests are kept"               'contract tests'

echo "testability"
LANG_DOC="$DIR/LANGUAGE.md"
has    "$LANG_DOC" "testability section"               '## Designing for testability'
has    "$LANG_DOC" "accept dependencies"               'Accept dependencies'
has    "$LANG_DOC" "return results"                    'Return results instead of side effects'
has    "$LANG_DOC" "small surface"                     'Small surface'
QS="$(awk 'index($0, "## Designing for testability") {f=1; next} f && /^## / {exit} f' "$LANG_DOC" | grep -c '^[0-9]\. .*?$' || true)"
if [ "$QS" -eq 3 ]; then ok "three interface-shrinking questions"; else no "three interface-shrinking questions (found $QS)"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
