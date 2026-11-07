#!/bin/bash
# config/cursor/rules/*.mdc are hand-kept mirrors of config/claude/rules/*.md.
# Nothing generates them, so a section added to a Claude rule silently never
# reaches Cursor. This suite fails when a rule has no mirror, when the heading
# lists differ, when a table row differs, or when a rule sentence that other
# runtimes depend on is missing from the mirror.
#
# Body prose is not compared: Cursor has its own tool names (memrain's bare
# `search` instead of the MCP-prefixed name, for one) and its own install paths.
#
# Mutation note: deleting `### Unattended loops` from a problem-solving.mdc copy,
# or a Status Vocabulary row from it, turns the check red (self-tests S1, S2).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
ROOT="$HERE/.."
CLAUDE_RULES="$ROOT/config/claude/rules"
CURSOR_RULES="$ROOT/config/cursor/rules"

# Deliberate differences, one per line: <rule>|<claude heading>|<cursor heading>.
# An empty side means the heading exists only on the other one.
HEADING_ALLOW='claude-code-usage|# Claude Code Usage|# Agent Usage
perf|## Effort + Plan Mode|## For Complex Tasks
skills|## Outside the pack|
skills|### Second opinion from another model|## Second opinion from another model'

# Rules whose tables legitimately differ: Cursor's skill table folds the
# built-in review and simplify commands into its main rows.
TABLE_EXEMPT=' skills '

# Sentences every runtime must carry, one per line: <rule>|<fixed string>.
PHRASES='problem-solving|not target acceptance
memrain|`meta.degraded`
memrain|`fact_supersessions`'

# Prints the body with a leading frontmatter block removed.
strip_frontmatter() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$1"
}

# Prints every markdown heading outside fenced blocks, one per line.
headings() {
  strip_frontmatter "$1" | awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f && /^#+ /'
}

# Prints every table row outside fenced blocks, skipping separator rows.
table_rows() {
  strip_frontmatter "$1" \
    | awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f && /^\|/ && !/^\|[-:| ]+\|$/'
}

# Rewrites a Claude heading list into the Cursor heading list it should match.
apply_allow() {
  local rule="$1" list="$2" r c k
  while IFS='|' read -r r c k; do
    [[ "$r" == "$rule" ]] || continue
    if [[ -n "$c" ]]; then
      list=$(printf '%s\n' "$list" | awk -v from="$c" -v to="$k" '$0 == from { if (to != "") print to; next } { print }')
    elif [[ -n "$k" ]]; then
      list=$(printf '%s\n%s\n' "$list" "$k")
    fi
  done <<< "$HEADING_ALLOW"
  printf '%s\n' "$list"
}

# Checks one rule pair; prints one FAIL line per problem, returns nonzero on any.
check_pair() {
  local md="$1" mdc="$2" rule want got diff_out r p bad=0
  rule="$(basename "$md" .md)"
  [[ -f "$mdc" ]] || { echo "FAIL M0: $rule.md has no Cursor mirror $(basename "$mdc")"; return 1; }

  want=$(apply_allow "$rule" "$(headings "$md")" | sed '/^$/d' | sort)
  got=$(headings "$mdc" | sort)
  if [[ "$want" != "$got" ]]; then
    diff_out=$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | grep -E '^[<>]' \
      | sed -e 's/^</missing from mirror:/' -e 's/^>/only in mirror:/')
    echo "FAIL M1: $rule headings differ —"
    printf '%s\n' "$diff_out" | sed 's/^/          /'
    bad=1
  fi

  if [[ "$TABLE_EXEMPT" != *" $rule "* ]]; then
    diff_out=$(diff <(table_rows "$md") <(table_rows "$mdc") | grep -E '^[<>]' \
      | sed -e 's/^</missing from mirror:/' -e 's/^>/only in mirror:/')
    if [[ -n "$diff_out" ]]; then
      echo "FAIL M2: $rule table rows differ —"
      printf '%s\n' "$diff_out" | sed 's/^/          /'
      bad=1
    fi
  fi

  while IFS='|' read -r r p; do
    [[ "$r" == "$rule" ]] || continue
    grep -qF -- "$p" "$md" || { echo "FAIL M3: $rule.md lacks '$p'"; bad=1; }
    grep -qF -- "$p" "$mdc" || { echo "FAIL M3: $rule.mdc lacks '$p'"; bad=1; }
  done <<< "$PHRASES"
  return "$bad"
}

for md in "$CLAUDE_RULES"/*.md; do
  rule="$(basename "$md" .md)"
  if out=$(check_pair "$md" "$CURSOR_RULES/$rule.mdc"); then
    _pass "$rule: mirror has the same headings, table rows and shared sentences"
  else
    _fail "$rule: Cursor mirror out of step"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

# Self-tests: each mutation of a mirror copy must turn the check red.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cursor-rules.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cp "$CLAUDE_RULES/problem-solving.md" "$TMP/problem-solving.md"

grep -vxF '### Unattended loops' "$CURSOR_RULES/problem-solving.mdc" > "$TMP/no-heading.mdc"
if out=$(check_pair "$TMP/problem-solving.md" "$TMP/no-heading.mdc"); then
  _fail "S1: dropping '### Unattended loops' from the mirror did not turn the check red"
elif grep -q 'Unattended loops' <<< "$out"; then
  _pass "S1: dropping '### Unattended loops' from the mirror fails and is named"
else
  _fail "S1: dropping '### Unattended loops' failed without naming it"
fi

grep -v '^| blocked |' "$CURSOR_RULES/problem-solving.mdc" > "$TMP/no-row.mdc"
if out=$(check_pair "$TMP/problem-solving.md" "$TMP/no-row.mdc"); then
  _fail "S2: dropping the 'blocked' status row did not turn the check red"
elif grep -q 'blocked' <<< "$out"; then
  _pass "S2: dropping the 'blocked' status row fails and is named"
else
  _fail "S2: dropping the 'blocked' status row failed without naming it"
fi

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
