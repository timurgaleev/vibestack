#!/bin/bash
# config/claude/rules/skills.md is loaded every session, so a row naming a skill
# that does not ship sends the model after a command that is not there, and a
# skill missing from the table is one the model never reaches for. This suite
# keeps the routing table and skills/ in step.
#
# Mutation note: adding a `/benchmark-models` row to the Task → skill table, or
# deleting the `/vibe` line, turns this suite red. Both mutations run below on a
# temp copy as self-tests (S1, S2).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
ROOT="$HERE/.."
SKILLS_DIR="$ROOT/skills"
RULE="$ROOT/config/claude/rules/skills.md"
HUB="$ROOT/config/claude/CLAUDE.md"
OUTSIDE_HEADING='## Outside the pack'

# Prints "<section> <name> <line>" for every backticked /name outside fenced
# blocks; section is "pack" above the outside heading, "outside" below it.
routing_tokens() {
  awk -v heading="$OUTSIDE_HEADING" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    $0 == heading { below = 1; next }
    {
      line = $0
      while (match(line, /`\/[A-Za-z0-9_-]+/)) {
        name = substr(line, RSTART + 2, RLENGTH - 2)
        print (below ? "outside" : "pack"), name, $0
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# Runs every routing check against <rule-file>; prints one FAIL line per
# problem and returns nonzero when any check failed.
check_routing() {
  local rule="$1" bad=0 section name line all missing=""
  grep -qxF "$OUTSIDE_HEADING" "$rule" || { echo "FAIL R0: no '$OUTSIDE_HEADING' heading"; bad=1; }
  while read -r section name line; do
    if [[ "$section" == pack ]]; then
      [[ -f "$SKILLS_DIR/$name/SKILL.md" ]] \
        || { echo "FAIL R1: /$name is in the Task → skill table but skills/$name/SKILL.md does not exist"; bad=1; }
    else
      [[ -e "$SKILLS_DIR/$name" ]] \
        && { echo "FAIL R2: /$name is a pack skill but sits under '$OUTSIDE_HEADING'"; bad=1; }
      grep -qE 'built-in|plugin' <<< "$line" \
        || { echo "FAIL R3: /$name under '$OUTSIDE_HEADING' names no origin (built-in or plugin)"; bad=1; }
    fi
  done < <(routing_tokens "$rule")
  all=$(routing_tokens "$rule" | awk '{ print $2 }' | sort -u)
  for dir in "$SKILLS_DIR"/*/; do
    name="$(basename "$dir")"
    [[ -f "$dir/SKILL.md" ]] || continue
    grep -qxF "$name" <<< "$all" || missing="$missing $name"
  done
  [[ -z "$missing" ]] || { echo "FAIL R4: skills not routed anywhere:$missing"; bad=1; }
  grep -qxF vibe <<< "$all" || { echo "FAIL R5: /vibe is not named"; bad=1; }
  return "$bad"
}

# R1-R5 against the shipped file.
if out=$(check_routing "$RULE"); then
  _pass "R1-R5: every routed name ships, outside names carry an origin, every skill is routed, /vibe is named"
else
  _fail "routing table out of step with skills/"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# H1: the hub routes pre-merge review to the pack's own skill.
if grep -qF '/code-review' "$HUB"; then
  _fail "H1: config/claude/CLAUDE.md names /code-review (route to /review)"
else
  _pass "H1: hub does not name /code-review"
fi

# Self-tests: each mutation must turn the check red.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/skills-routing.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

awk -v heading="$OUTSIDE_HEADING" '
  $0 == heading && !done { print "| Compare models | `/benchmark-models` |"; print ""; done = 1 }
  { print }
' "$RULE" > "$TMP/withdrawn.md"
if out=$(check_routing "$TMP/withdrawn.md"); then
  _fail "S1: a /benchmark-models row did not turn the check red"
elif grep -q 'benchmark-models' <<< "$out"; then
  _pass "S1: a /benchmark-models row fails and is named"
else
  _fail "S1: a /benchmark-models row failed without naming it"
fi

grep -v '`/vibe`' "$RULE" > "$TMP/no-vibe.md"
if out=$(check_routing "$TMP/no-vibe.md"); then
  _fail "S2: deleting the /vibe lines did not turn the check red"
elif grep -q 'vibe' <<< "$out"; then
  _pass "S2: deleting the /vibe lines fails and is named"
else
  _fail "S2: deleting the /vibe lines failed without naming it"
fi

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
