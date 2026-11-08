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
# Copilot documents no total listing cap, but each description is capped at
# 1024 chars; a longer one is a skill that does not load as written.
run --skills-dir "$SK" --config-dir "" --runtime copilot
[ "$(field BUDGET)" = none ] && [ "$RC" = 0 ] && ok "copilot reports the total, does not gate it" \
  || bad "copilot reports the total, does not gate it (rc=$RC)" "$OUT"
CAP="$TMP/cap"
mk_skill "$CAP" ok1024 "description: $(printf 'x%.0s' $(seq 1024))"
run --skills-dir "$CAP" --config-dir "" --runtime copilot
[ "$RC" = 0 ] && ok "copilot accepts a 1024-char description" || bad "copilot accepts a 1024-char description (rc=$RC)" "$OUT"
mk_skill "$CAP" long1025 "description: $(printf 'x%.0s' $(seq 1025))"
run --skills-dir "$CAP" --config-dir "" --runtime copilot
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q 'long1025.*1025.*1024' \
  && ok "copilot rejects a 1025-char description and names it" \
  || bad "copilot rejects a 1025-char description and names it (rc=$RC)" "$OUT"
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

echo "per-skill size (--skill)"
# A skill's body and the sub-docs it reads on demand are paid for when it runs,
# not at listing time, so --skill reports them for one skill without gating.
SOLO="$TMP/solo-skills"
mk_skill "$SOLO" solo "description: One skill."
mkdir -p "$SOLO/solo/sub" "$SOLO/solo/bin"
printf '%0100d' 0 > "$SOLO/solo/notes.md"
printf '%050d' 0 > "$SOLO/solo/sub/deep.md"
printf '%030d' 0 > "$SOLO/solo/bin/helper.md"
printf '{"not":"a doc"}' > "$SOLO/solo/data.json"
solo_rendered=$("$ROOT/bin/vibe-render-skill" "$SOLO/solo/SKILL.md" "$TMP/solo-rendered.md" >/dev/null 2>&1 \
  && wc -c < "$TMP/solo-rendered.md" | tr -d ' ')
run --skills-dir "$SOLO" --skill solo
[ "$RC" = 0 ] && ok "--skill exits 0" || bad "--skill exits 0 (rc=$RC)" "$OUT"
[ -n "$solo_rendered" ] && [ "$(field RENDERED_BYTES)" = "$solo_rendered" ] \
  && ok "RENDERED_BYTES is the rendered SKILL.md size ($solo_rendered)" \
  || bad "RENDERED_BYTES is the rendered SKILL.md size (want ${solo_rendered:-?}, got $(field RENDERED_BYTES))" "$OUT"
[ "$(field SIBLING_DOC_BYTES)" = "150 (2 docs)" ] \
  && ok "sibling .md docs summed at any depth, bin/ and non-.md files skipped" \
  || bad "sibling .md docs summed at any depth, bin/ and non-.md files skipped (got $(field SIBLING_DOC_BYTES))" "$OUT"
printf '%s\n' "$OUT" | grep -Eq '^  sub/deep\.md +50$' && ok "each sibling doc listed with its bytes" \
  || bad "each sibling doc listed with its bytes" "$OUT"
[ "$(field SKILL_BYTES)" = "$(( ${solo_rendered:-0} + 150 ))" ] && ok "SKILL_BYTES is rendered + sibling docs" \
  || bad "SKILL_BYTES is rendered + sibling docs (got $(field SKILL_BYTES))" "$OUT"
printf '%s\n' "$OUT" | grep -q '^TOTAL ' && bad "--skill skips the listing report" "$OUT" \
  || ok "--skill skips the listing report"
run --skills-dir "$SOLO" --skill nope
[ "$RC" = 2 ] && ok "--skill with an unknown name exits 2" || bad "--skill with an unknown name exits 2 (rc=$RC)" "$OUT"
run --skills-dir "$SOLO" --skill ../solo
[ "$RC" = 2 ] && ok "--skill rejects a path instead of a name" || bad "--skill rejects a path instead of a name (rc=$RC)" "$OUT"
run --skills-dir "$SOLO" --skill
[ "$RC" = 2 ] && ok "--skill without a value exits 2" || bad "--skill without a value exits 2 (rc=$RC)" "$OUT"
# An install links sub-doc directories in; their docs still count.
INST="$TMP/installed"; mkdir -p "$INST/solo"
cp "$TMP/solo-rendered.md" "$INST/solo/SKILL.md"
ln -s "$SOLO/solo/sub" "$INST/solo/sub"
ln -s "$SOLO/solo/notes.md" "$INST/solo/notes.md"
run --rendered "$INST" --skill solo
[ "$(field RENDERED_BYTES)" = "$solo_rendered" ] && [ "$(field SIBLING_DOC_BYTES)" = "150 (2 docs)" ] \
  && ok "--rendered --skill measures an install through its symlinks" \
  || bad "--rendered --skill measures an install through its symlinks" "$OUT"
review_rendered=$("$ROOT/bin/vibe-render-skill" "$ROOT/skills/review/SKILL.md" "$TMP/review.md" >/dev/null 2>&1 \
  && wc -c < "$TMP/review.md" | tr -d ' ')
review_docs=$(find "$ROOT/skills/review" -name '*.md' ! -path '*/bin/*' ! -path "$ROOT/skills/review/SKILL.md" \
  -exec cat {} + | wc -c | tr -d ' ')
run --skill review
[ "$(field RENDERED_BYTES)" = "$review_rendered" ] && [ "$(field SIBLING_DOC_BYTES | cut -d' ' -f1)" = "$review_docs" ] \
  && ok "the real review skill: rendered $review_rendered + docs $review_docs" \
  || bad "the real review skill (want $review_rendered + $review_docs)" "$OUT"

echo "the real pack"
run --budget 1000000
[ "$RC" = 0 ] && ok "measures the repo's own skills" || bad "measures the repo's own skills (rc=$RC)" "$OUT"
real_skills=$(ls -d "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')
[ "$(field SKILLS)" = "$real_skills" ] && ok "every skill in skills/ is counted ($real_skills)" \
  || bad "every skill in skills/ is counted (want $real_skills, got $(field SKILLS))" "$OUT"
printf '%s\n' "$OUT" | grep -q '^warning:' && bad "no frontmatter warnings on the real pack" "$OUT" \
  || ok "no frontmatter warnings on the real pack"
# Codex shortens or drops skills once the listing passes its cap, so the pack
# itself must fit the default codex budget, not just measure cleanly.
run --config-dir ""
real_total="$(field TOTAL)"
[ "$RC" = 0 ] && [ -n "$real_total" ] && [ "$real_total" -le 8000 ] \
  && ok "the pack fits the default codex budget ($real_total <= 8000)" \
  || bad "the pack fits the default codex budget (TOTAL ${real_total:-?}, rc=$RC)" "$(printf '%s\n' "$OUT" | grep -E '^(TOTAL|BUDGET|OVER BUDGET)')"
# A new skill or a longer description lands without warning; keeping 300 chars
# free means the next addition is a deliberate trim, not a silent Codex cut.
[ -n "$real_total" ] && [ "$real_total" -le 7700 ] \
  && ok "the pack keeps 300 chars of headroom ($real_total <= 7700)" \
  || bad "the pack keeps 300 chars of headroom (TOTAL ${real_total:-?} > 7700): trim descriptions"

run --config-dir "" --runtime copilot
[ "$RC" = 0 ] && ok "every pack description fits copilot's 1024-char cap" \
  || bad "every pack description fits copilot's 1024-char cap (rc=$RC)" "$(printf '%s\n' "$OUT" | grep -i 'cap')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
