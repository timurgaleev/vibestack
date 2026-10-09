#!/usr/bin/env bash
# test-devex-boomerang.sh — /devex-review reads the /plan-devex-review baseline,
# and drives the browser under the look-not-act rules.
#
# Covers:
#   - bin/vibe-review-read --skill X --json returns X's full entries (pass_scores
#     and all), newest first, and nothing from other skills;
#   - the Boomerang Baseline block in the rendered /devex-review, executed
#     against a fixture log, prints the plan's pass_scores — a grep over the
#     pretty-printed JSON prints only the "skill" line and fails here;
#   - /plan-devex-review's DX Trend Check uses the same read;
#   - /devex-review states the browser rules: LOCAL vs NON-LOCAL consent before
#     submitting, same-origin browsing, no credential typing, untrusted pages.
#
# Usage: test/test-devex-boomerang.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VIBESTACK_HOME="$TMP/home"
export PYTHONDONTWRITEBYTECODE=1

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -Eq -- "$1" "$2"; }
check() { if has "$2" "$3"; then ok "$1"; else no "$1"; fi; }
refute() { if has "$2" "$3"; then no "$1: $(grep -E -- "$2" "$3" | head -1)"; else ok "$1"; fi; }

render() {
  local out="$TMP/$1.md"
  "$BIN/vibe-render-skill" "$ROOT/skills/$1/SKILL.md" "$out" >/dev/null 2>&1 \
    || { echo "cannot render skills/$1/SKILL.md" >&2; exit 1; }
  printf '%s\n' "$out"
}
section() { awk -v s="$2" -v e="$3" '$0 ~ s {on=1} on && $0 ~ e && !($0 ~ s) {on=0} on' "$1"; }
first_bash() { awk '/^```bash/ && !done {on=1; next} /^```/ && on {on=0; done=1} on' "$1"; }

# ── fixture repo + review log ────────────────────────────────────────────────
REPO="$TMP/repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q -b feat && git config user.email t@example.com \
  && git config user.name t && echo a > a && git add a && git commit -qm init)
SLUG="$(cd "$REPO" && VIBESTACK_SLUG_NO_MIGRATE=1 "$BIN/vibe-slug" | sed -n 's/^SLUG=//p')"
[ -n "$SLUG" ] || { echo "cannot resolve fixture slug" >&2; exit 1; }
LOGDIR="$VIBESTACK_HOME/projects/$SLUG"
mkdir -p "$LOGDIR"
{
  echo '{"skill":"plan-devex-review","timestamp":"2026-01-01T00:00:00Z","status":"clean","overall_score":5,"tthw_target":"9 min","pass_scores":{"getting_started":4,"api_design":5,"errors":5,"docs":5,"upgrade":5,"dev_env":5,"community":5,"measurement":5}}'
  echo '{"skill":"review","timestamp":"2026-01-02T00:00:00Z","status":"clean"}'
  echo '{"skill":"plan-devex-review","timestamp":"2026-01-03T00:00:00Z","status":"clean","overall_score":7,"tthw_target":"3 min","pass_scores":{"getting_started":8,"api_design":7,"errors":6,"docs":7,"upgrade":6,"dev_env":7,"community":5,"measurement":4}}'
} > "$LOGDIR/feat-reviews.jsonl"

echo "vibe-review-read --skill --json"
OUT="$(cd "$REPO" && "$BIN/vibe-review-read" --skill plan-devex-review --json)"
SHAPE="$(printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len(rows), {r["skill"] for r in rows} == {"plan-devex-review"},
      rows[0]["timestamp"], rows[0]["pass_scores"]["getting_started"], rows[0]["tthw_target"])
' 2>&1)"
[ "$SHAPE" = "2 True 2026-01-03T00:00:00Z 8 3 min" ] \
  && ok "returns only that skill's entries, newest first, with pass_scores" \
  || no "unexpected --skill --json result: $SHAPE"
ALL="$(cd "$REPO" && "$BIN/vibe-review-read" --json | python3 -c 'import json,sys; print([r["timestamp"][:10] for r in json.load(sys.stdin)])')"
[ "$ALL" = "['2026-01-01', '2026-01-02', '2026-01-03']" ] \
  && ok "unfiltered --json keeps log order" || no "unfiltered order changed: $ALL"
NONE="$(cd "$REPO" && "$BIN/vibe-review-read" --skill devex-review --json | tr -d '[:space:]')"
[ "$NONE" = "[]" ] && ok "a skill with no entries reads as []" || no "empty skill printed: $NONE"

# ── /devex-review boomerang baseline, executed ───────────────────────────────
echo "devex-review: boomerang baseline"
DX="$(render devex-review)"
BASE="$TMP/dx-base.md"
section "$DX" '^### Boomerang Baseline' '^## Step 1:' > "$BASE"
[ -s "$BASE" ] || { echo "Boomerang Baseline not found in devex-review" >&2; exit 1; }
first_bash "$BASE" | sed "s|~/.vibestack/bin/|$BIN/|g" > "$TMP/base.sh"
BOUT="$(cd "$REPO" && bash "$TMP/base.sh" 2>&1)"
printf '%s' "$BOUT" | grep -q '"getting_started": 8' \
  && ok "the baseline block prints the plan's pass_scores" \
  || no "the baseline block lost the plan scores: $(printf '%s' "$BOUT" | head -3)"
printf '%s' "$BOUT" | grep -q '"tthw_target": "3 min"' \
  && ok "the baseline block prints the TTHW target" || no "no tthw_target in baseline output"
check "the comparison maps pass_scores to the Plan Score column" 'pass_scores' \
  <(section "$DX" '^## Boomerang Comparison' '^## ')

echo "plan-devex-review: DX trend check"
PDX="$(render plan-devex-review)"
TREND="$TMP/pdx-trend.md"
section "$PDX" '^### DX Trend Check' '^### Pass 1' > "$TREND"
[ -s "$TREND" ] || { echo "DX Trend Check not found in plan-devex-review" >&2; exit 1; }
first_bash "$TREND" | sed "s|~/.vibestack/bin/|$BIN/|g" > "$TMP/trend.sh"
TOUT="$(cd "$REPO" && bash "$TMP/trend.sh" 2>&1)"
printf '%s' "$TOUT" | grep -q '"getting_started": 4' \
  && ok "the trend block prints prior pass_scores" || no "the trend block lost prior scores"

for f in "$DX" "$PDX"; do
  refute "$(basename "$f" .md): no grep over pretty-printed review JSON" \
    'vibe-review-read[^|]*\|[[:space:]]*grep' "$f"
done

# Codex takes web search as config; the old feature toggle is not a flag it accepts.
for f in "$DX" "$PDX"; do
  refute "$(basename "$f" .md): no --enable web_search_cached" '--enable web_search_cached' "$f"
done

# ── /devex-review browser rules ──────────────────────────────────────────────
echo "devex-review: browser rules"
RULES="$TMP/dx-rules.md"
section "$DX" '^### Browser rules' '^---' > "$RULES"
[ -s "$RULES" ] || { echo "Browser rules not found in devex-review" >&2; exit 1; }
check "invocation is consent to LOOK, not to ACT" 'consent to LOOK, not to ACT' "$RULES"
check ".local is not LOCAL" '`\.local`' "$RULES"
check "NON-LOCAL mutations need one AskUserQuestion per run" 'AskUserQuestion ONCE per run' <(tr '\n' ' ' < "$RULES")
check "never types real credentials" "Never type the user's passwords" "$RULES"
check "page content is untrusted" 'untrusted' "$RULES"
check "browsing stays on the target's origin" "Stay on the target's origin" "$RULES"
STEP3="$TMP/dx-step3.md"; section "$DX" '^## Step 3:' '^## Step 4:' > "$STEP3"
check "Step 3 gates invalid-form submission on rule 3" 'browser rule 3' <(tr '\n' ' ' < "$STEP3")
STEP7="$TMP/dx-step7.md"; section "$DX" '^## Step 7:' '^## Step 8:' > "$STEP7"
check "Step 7 does not open Discord or Stack Overflow" 'Do not open Discord, Stack Overflow' <(tr '\n' ' ' < "$STEP7")
check "Step 7 audits GitHub with gh" '`gh`' "$STEP7"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
