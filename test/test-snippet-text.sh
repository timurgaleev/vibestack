#!/usr/bin/env bash
# test-snippet-text.sh — wording in shared snippets that a model copies or obeys
# literally.
#
# Covers:
#   - the plan-file review report and the plan-devex-review hall-of-fame pointer
#     carry real backticks: a `\`` in skill text is copied verbatim into the
#     report the model writes, so plan files end up with literal backslashes;
#   - the /qa and /qa-only probe rules treat a wizard or dialog step on a
#     NON-LOCAL target as mutating, read back every filled value before a
#     Save/Submit, and extend "look, not act" to the functional surface.
#
# Usage: test/test-snippet-text.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -Eq -- "$1" "$2"; }
check() { if has "$2" "$3"; then ok "$1"; else no "$1"; fi; }
refute() { if has "$2" "$3"; then no "$1: $(grep -E -- "$2" "$3" | head -1)"; else ok "$1"; fi; }

render() {
  local name="$1" out="$TMP/$1.md"
  if ! "$ROOT/bin/vibe-render-skill" "$ROOT/skills/$name/SKILL.md" "$out" >/dev/null 2>&1; then
    echo "cannot render skills/$name/SKILL.md" >&2; exit 1
  fi
  printf '%s\n' "$out"
}

# section FILE START_RE END_RE — lines from START up to (not including) END.
section() { awk -v s="$2" -v e="$3" '$0 ~ s {on=1; print; next} on && $0 ~ e {on=0} on' "$1"; }

ESC='\\`'

echo "plan-file review report: no escaped backticks"
REPORT="$ROOT/lib/snippets/plan-file-review-report.md"
refute "snippet has no \\\` sequence" "$ESC" "$REPORT"
check "report template is a real markdown fence" '^```markdown$' "$REPORT"
check "report trigger column uses plain backticks" '^\| CEO Review \| `/plan-ceo-review` \|' "$REPORT"
for name in plan-ceo-review plan-eng-review plan-design-review plan-devex-review; do
  R="$(render "$name")"
  section "$R" '^## Plan File Review Report' '^### Write to the plan file' > "$TMP/$name-report.md"
  [ -s "$TMP/$name-report.md" ] || no "$name: Plan File Review Report section not found"
  refute "$name: rendered report section has no \\\`" "$ESC" "$TMP/$name-report.md"
done

echo "plan-devex-review: hall-of-fame pointer"
R="$(render plan-devex-review)"
section "$R" '^## Hall of Fame Reference' '^## ' > "$TMP/hof.md"
[ -s "$TMP/hof.md" ] || no "Hall of Fame Reference section not found"
refute "hall-of-fame path is not wrapped in \\\`" "$ESC" "$TMP/hof.md"
check "hall-of-fame path is in plain backticks" '^`[^`\\]*dx-hall-of-fame\.md`$' "$TMP/hof.md"

for name in qa qa-only; do
  echo "$name: probe rules on the functional surface"
  R="$(render "$name")"
  RULES="$TMP/$name-rules.md"
  section "$R" '^## Rules for probing the target' '^## ' > "$RULES"
  [ -s "$RULES" ] || { no "$name: probe rules section not found"; continue; }
  check "$name: invocation is not permission for external mutation" \
    'not permission for external mutation' "$RULES"
  check "$name: a wizard or dialog step on NON-LOCAL counts as mutating" \
    'wizard or dialog step on a NON-LOCAL target is mutating' "$RULES"
  check "$name: Cancel proves nothing" 'Cancel proves nothing' "$RULES"
  check "$name: reads back every filled or selected value" \
    'read back every value you filled or selected' "$RULES"
  section "$RULES" 'wizard or dialog step' '^[0-9]+\. ' > "$TMP/$name-wizard.md"
  check "$name: read-back names \$B js" '`\$B js` for an input' "$TMP/$name-wizard.md"
  check "$name: read-back names \$B attrs" '`\$B attrs` for attribute state' "$TMP/$name-wizard.md"
  check "$name: read-back happens before any Save/Submit" '[Bb]efore any Save or Submit' "$RULES"
  check "$name: stops on a read-back mismatch" 'mismatch.*(STOP|stop)' "$RULES"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
