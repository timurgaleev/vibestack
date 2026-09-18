#!/bin/bash
# config/codex/AGENTS.md is generated from config/claude/CLAUDE.md + config/claude/rules/. This suite
# fails when the two drift — edit the source and re-run the generator.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
GEN="$HERE/../scripts/gen-codex-agents.py"
AGENTS="$HERE/../config/codex/AGENTS.md"

# Single source for the rule-filename grammar: read it out of the generator so
# the checks below cannot drift from what the generator actually matches.
RULE_NAME=$(sed -n 's/^RULE_NAME = r"\(.*\)"$/\1/p' "$GEN")
[[ -n "$RULE_NAME" ]] || { echo "  FAIL: could not read RULE_NAME from $GEN"; exit 1; }

# G1: the committed AGENTS.md matches what the generator produces.
test_no_drift() {
  if python3 "$GEN" --check >/dev/null 2>&1; then
    _pass "G1: codex/AGENTS.md is up to date"
  else
    _fail "G1: codex/AGENTS.md is stale — run scripts/gen-codex-agents.py"
  fi
}

# G2: no pointer to a rules/ file survives outside a fenced block. Codex has no
# rules directory, so a surviving link sends it looking for a file that does not
# exist. Fenced examples are exempt — the generator preserves them on purpose.
test_no_dangling_rule_links() {
  if awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f' "$AGENTS" \
     | grep -qE "rules/${RULE_NAME}\.md"; then
    _fail "G2: dangling rules/*.md reference outside a fenced block"
  else
    _pass "G2: no dangling rules/*.md references"
  fi
}

# G3: Claude-Code-only tool names must not leak into Codex instructions.
test_no_claude_tool_names() {
  local leaked=""
  local term
  for term in EnterPlanMode ExitPlanMode "the Skill tool"; do
    grep -q "$term" "$AGENTS" && leaked="$leaked $term"
  done
  if [[ -n "$leaked" ]]; then
    _fail "G3: Claude-only tool names in AGENTS.md:$leaked"
  else
    _pass "G3: no Claude-only tool names"
  fi
}

# G4: every rule file is accounted for at the source. A new rule that nothing
# points at would be silently dropped from AGENTS.md, and G1 would not notice —
# the generator's output would match its own omission.
test_rules_accounted_for() {
  local used missing="" path name
  used=$(python3 "$GEN" --report-rules 2>/dev/null) || {
    _fail "G4: generator could not report the rules it used"
    return
  }
  for path in "$HERE"/../config/claude/rules/*.md; do
    name="$(basename "$path" .md)"
    # Excluded on purpose, each with a reason recorded in the generator:
    # perf (picks a Claude model tier), claude-code-usage (Claude-only tools),
    # skills (folded into the Codex Usage section).
    case "$name" in perf|claude-code-usage|skills) continue ;; esac
    # A filename outside the generator's grammar could never be expanded, so
    # reject it here rather than let it look accounted for.
    if ! printf '%s' "$name" | grep -qE "^${RULE_NAME}$"; then
      missing="$missing ${name}(unsupported-filename)"
      continue
    fi
    grep -qxF "$name" <<< "$used" || missing="$missing $name"
  done
  if [[ -n "$missing" ]]; then
    _fail "G4: rules the generator never inlined or appended:$missing"
  else
    _pass "G4: every applicable rule is actually consumed by the generator"
  fi
}

test_no_drift
test_no_dangling_rule_links
test_no_claude_tool_names
test_rules_accounted_for

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
