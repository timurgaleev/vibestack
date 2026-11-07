#!/usr/bin/env bash
# test-test-bootstrap.sh — lib/snippets/test-bootstrap.md stays the one wording
# of test-framework detection that /ship and /qa render.
#
# Until each skill includes the snippet, it carries an inline copy; the checks
# run on rendered output, so they keep holding after the switch to the include.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNIPPET="$ROOT/lib/snippets/test-bootstrap.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# First ```bash fence after the "## Test Framework Bootstrap" heading
# (the whole file when there is no such heading).
detection_block() {
  awk '
    /^## Test Framework Bootstrap$/ { seen=1 }
    !seen && FILENAME !~ /test-bootstrap\.md$/ { next }
    /^```bash$/ && !done { inb=1 }
    inb { print }
    inb && /^```$/ { inb=0; done=1 }
  ' "$1"
}

RULE_PREFIX='**If ANY existing-test evidence appears**'

echo "snippet"
if [ ! -f "$SNIPPET" ]; then
  no "missing $SNIPPET"
  echo; echo "passed: $pass  failed: $fail"; exit 1
fi
detection_block "$SNIPPET" > "$TMP/snippet-block"
[ -s "$TMP/snippet-block" ] && ok "snippet carries a detection block" || no "snippet has no bash detection block"
for needle in 'SCRIPT:package.json test' 'TARGET:make test' 'TESTFILES:' 'TESTS:rust in-source' \
              'NOT evidence of "no tests"' 'Existing tests detected: {the evidence}'; do
  grep -Fq -- "$needle" "$SNIPPET" && ok "snippet: $needle" || no "snippet missing: $needle"
done
# Included from several skills, so it must not point at any one skill's steps.
if grep -Eq '(Step|Phase) [0-9]' "$SNIPPET"; then
  no "snippet names a skill-specific step or phase"
else
  ok "snippet names no skill-specific step"
fi
if grep -Eq '^\{\{include ' "$SNIPPET"; then
  no "snippet contains a nested include"
else
  ok "snippet has no nested include"
fi

echo "rendered skills"
for skill in ship qa; do
  out="$TMP/$skill.md"
  if ! "$ROOT/bin/vibe-render-skill" "$ROOT/skills/$skill/SKILL.md" "$out" >/dev/null 2>&1; then
    no "$skill: render failed"; continue
  fi
  detection_block "$out" > "$TMP/$skill-block"
  if cmp -s "$TMP/snippet-block" "$TMP/$skill-block"; then
    ok "$skill: detection block is byte-identical to the snippet"
  else
    no "$skill: detection block drifted from the snippet"
    diff "$TMP/snippet-block" "$TMP/$skill-block" | head -10 | sed 's/^/       /'
  fi
  missing=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # /ship's inline copy names its own Step 5 in this rule; the include drops that.
    if [ "$skill" = ship ] && [ "${line#"$RULE_PREFIX"}" != "$line" ]; then
      grep -Fq -- "$RULE_PREFIX" "$out" || { no "$skill: existing-tests rule missing"; missing=1; }
      continue
    fi
    grep -Fxq -- "$line" "$out" || { no "$skill: lacks snippet line: ${line:0:60}"; missing=1; }
  done < "$SNIPPET"
  [ "$missing" -eq 0 ] && ok "$skill: renders every snippet line"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
