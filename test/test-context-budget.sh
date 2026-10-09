#!/usr/bin/env bash
# test-context-budget.sh — vibe-context-budget counts what the runtime lists,
# and its gate fails when the listing is over budget.
#
# A budget check that miscounts is worse than none: it reports a pass while
# Codex is quietly shortening descriptions. So the counts are asserted on
# fixtures with known lengths, in every frontmatter shape the pack writes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/vibe-context-budget"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

# run <args...> — sets OUT and RC
run() { OUT="$("$BIN" "$@" 2>&1)"; RC=$?; }
field() { printf '%s\n' "$OUT" | sed -n "s/^$1 //p" | head -n1; }

mk_skill() { # mk_skill <dir> <name> <frontmatter-description-lines...>
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir/$name"
  { echo "---"; echo "name: $name"; printf '%s\n' "$@"; echo "allowed-tools:"; echo "  - Read"; echo "---"; echo; echo "# $name"; } \
    > "$dir/$name/SKILL.md"
}

SK="$TMP/skills"
# Lengths are chosen so every shape contributes a distinct, checkable number.
mk_skill "$SK" alpha "description: Plain one-liner."                       # name 5 + desc 16
mk_skill "$SK" beta  'description: "Quoted value."'                         # name 4 + desc 13
mk_skill "$SK" gamma "description: |" "  Line one." "  Line two." ""        # name 5 + desc 9+1+9 = 19
mk_skill "$SK" delta "description: >" "  Folded one" "  folded two."        # name 5 + desc 22
EXPECT=$(( 5+16 + 4+13 + 5+19 + 5+22 ))
EMPTY_CFG="$TMP/cfg"; mkdir -p "$EMPTY_CFG"

echo "counts"
run --skills-dir "$SK" --config-dir "" --budget 10000
[ "$(field SKILLS)" = 4 ] && ok "four skills found" || bad "four skills found" "$OUT"
[ "$(field TOTAL)" = "$EXPECT" ] && ok "plain, quoted, | and > descriptions sum to $EXPECT" \
  || bad "plain, quoted, | and > descriptions sum to $EXPECT (got $(field TOTAL))" "$OUT"
[ "$RC" = 0 ] && ok "within budget exits 0" || bad "within budget exits 0 (rc=$RC)" "$OUT"
printf '%s\n' "$OUT" | grep -Eq '^  delta +5 +22 +27 ' && ok "per-skill row shows name/desc/total" \
  || bad "per-skill row shows name/desc/total" "$OUT"
printf '%s\n' "$OUT" | head -n4 | tail -n1 | grep -q 'delta' && ok "heaviest skill ranked first" \
  || bad "heaviest skill ranked first" "$OUT"

echo "gate"
run --skills-dir "$SK" --config-dir "" --budget $((EXPECT - 1))
[ "$RC" = 1 ] && ok "one char over budget exits 1" || bad "one char over budget exits 1 (rc=$RC)" "$OUT"
printf '%s\n' "$OUT" | grep -q 'OVER BUDGET: '"$EXPECT"' / '"$((EXPECT - 1))" && ok "over-budget line names total and budget" \
  || bad "over-budget line names total and budget" "$OUT"
run --skills-dir "$SK" --config-dir "" --budget "$EXPECT"
[ "$RC" = 0 ] && ok "exactly at budget passes" || bad "exactly at budget passes (rc=$RC)" "$OUT"
run --skills-dir "$SK" --config-dir "" --budget 1 --warn-only
[ "$RC" = 0 ] && ok "--warn-only reports but exits 0" || bad "--warn-only reports but exits 0 (rc=$RC)" "$OUT"
printf '%s\n' "$OUT" | grep -q 'OVER BUDGET' && ok "--warn-only still prints the overage" || bad "--warn-only still prints the overage" "$OUT"
OUT="$(VIBESTACK_CONTEXT_BUDGET=1 "$BIN" --skills-dir "$SK" --config-dir "" 2>&1)"; RC=$?
[ "$RC" = 1 ] && ok "VIBESTACK_CONTEXT_BUDGET sets the budget" || bad "VIBESTACK_CONTEXT_BUDGET sets the budget (rc=$RC)" "$OUT"

echo "runtimes"
run --skills-dir "$SK" --config-dir ""
[ "$(field BUDGET)" = 8000 ] && ok "codex defaults to 8000" || bad "codex defaults to 8000" "$OUT"
run --skills-dir "$SK" --config-dir "" --runtime claude
[ "$(field BUDGET)" = none ] && [ "$RC" = 0 ] && ok "runtime without a known cap reports, does not gate" \
  || bad "runtime without a known cap reports, does not gate (rc=$RC)" "$OUT"
run --skills-dir "$SK" --config-dir "" --runtime nope
[ "$RC" = 2 ] && ok "unknown runtime exits 2" || bad "unknown runtime exits 2 (rc=$RC)" "$OUT"
run --skills-dir "$SK" --config-dir "" --budget lots
[ "$RC" = 2 ] && ok "non-numeric budget exits 2" || bad "non-numeric budget exits 2 (rc=$RC)" "$OUT"
run --skills-dir "$TMP/missing"
[ "$RC" = 2 ] && ok "missing skills dir exits 2" || bad "missing skills dir exits 2 (rc=$RC)" "$OUT"

echo "rendered input"
# --rendered measures an install as-is, so a skill whose description sits in
# an installed copy is counted without going through the renderer.
REN="$TMP/rendered"
mk_skill "$REN" only "description: Twelve chars"
run --rendered "$REN" --config-dir "" --budget 100
[ "$(field TOTAL)" = $((4 + 12)) ] && ok "--rendered counts an installed dir" || bad "--rendered counts an installed dir" "$OUT"

echo "config report"
CFG="$TMP/config"; mkdir -p "$CFG/rules" "$CFG/agents"
printf '%0100d' 0 > "$CFG/CLAUDE.md"
printf '%050d' 0 > "$CFG/rules/a.md"
printf -- '---\nname: x\ndescription: Ten chars.\n---\nbody\n' > "$CFG/agents/x.md"
printf 'readme is not an agent\n' > "$CFG/agents/README.md"
run --skills-dir "$SK" --config-dir "$CFG" --budget 10000
[ "$(field CONFIG_BYTES)" = 150 ] && ok "CLAUDE.md + rules bytes summed" || bad "CLAUDE.md + rules bytes summed" "$OUT"
printf '%s\n' "$OUT" | grep -q '^AGENT_DESC_CHARS 10 (1 agents)' && ok "agent descriptions counted, README skipped" \
  || bad "agent descriptions counted, README skipped" "$OUT"
[ "$RC" = 0 ] && ok "config size never gates" || bad "config size never gates (rc=$RC)" "$OUT"

echo "the real pack"
run --budget 1000000
[ "$RC" = 0 ] && ok "measures the repo's own skills" || bad "measures the repo's own skills (rc=$RC)" "$OUT"
real_skills=$(ls -d "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')
[ "$(field SKILLS)" = "$real_skills" ] && ok "every skill in skills/ is counted ($real_skills)" \
  || bad "every skill in skills/ is counted (want $real_skills, got $(field SKILLS))" "$OUT"
printf '%s\n' "$OUT" | grep -q '^warning:' && bad "no frontmatter warnings on the real pack" "$OUT" \
  || ok "no frontmatter warnings on the real pack"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
