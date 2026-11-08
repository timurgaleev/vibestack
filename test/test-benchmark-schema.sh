#!/usr/bin/env bash
# test-benchmark-schema.sh — contracts the /benchmark skill text must keep.
#
# Covers:
#   - one page load feeds every metric: a single `$B js` returns
#     {nav,fcp,lcp,resources,scripts,css,summary}, and a non-2xx navigation
#     fails the run instead of being measured;
#   - repeat runs: 5 loads per page, per-metric median plus [min,max]; the
#     baseline JSON carries `runs` and `range_ms` (a legacy baseline counts as
#     one run); a delta inside the spread is OK, a one-run comparison is
#     inconclusive, and --quick is one run with no verdict;
#   - the report leads with a verdict (faster / slower / no difference /
#     inconclusive), names the limiter and counts failed loads;
#   - the budget grade: FAIL at or over budget, WARNING at 90-100%, missing =
#     N/A, grade by the share under budget; no-baseline and zero-baseline rules;
#   - reports are named by a UTC timestamp, never a bare date;
#   - the description names a web performance benchmark and the body points
#     model comparisons and API/build timing elsewhere;
#   - Phase 1 refreshes the git index before reading the tree.
#
# Usage: test/test-benchmark-schema.sh [repo-root]
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

SKILL="$TMP/benchmark/SKILL.md"
if VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/benchmark/SKILL.md" "$SKILL" >/dev/null 2>&1; then
  ok "benchmark renders"
else
  no "benchmark renders"; echo "$pass passed, $fail failed"; exit 1
fi

has()   { if grep -qF -- "$3" "$1"; then ok "$2"; else no "$2 (missing: $3)"; fi; }
hasnt() { if grep -qF -- "$3" "$1"; then no "$2 (still present: $3)"; else ok "$2"; fi; }

# Body of one "### " section, so a phrase elsewhere cannot satisfy it.
section() { awk -v h="$1" 'index($0, h) == 1 {f=1; next} f && /^##+ / {exit} f' "$SKILL"; }

section '### Phase 1' > "$TMP/p1"
section '### Phase 3' > "$TMP/p3"
section '### Phase 4' > "$TMP/p4"
section '### Phase 5' > "$TMP/p5"
section '### Phase 7' > "$TMP/p7"
section '### Phase 9' > "$TMP/p9"
section '### Vet the number' > "$TMP/vet"

echo "description and scope"
DESC="$(awk '/^description:/ {f=1; next} f && /^[a-z-]+:/ {exit} f' "$SKILL" | tr -s ' \n' ' ')"
case "$DESC" in
  *'eb performance benchmark'*) ok "description names a web performance benchmark" ;;
  *) no "description names a web performance benchmark (got:$DESC)" ;;
esac
if [ "${#DESC}" -le 100 ]; then ok "description stays short (${#DESC} chars)"; else no "description stays short (${#DESC} chars > 100)"; fi
has "$SKILL" "model comparisons point to /agent-eval"      '/agent-eval'
has "$SKILL" "model comparisons point to ask-all"          '/deliberation:ask-all'
has "$SKILL" "API/build timing points to the agent"        'performance-benchmarker'

echo "setup"
has "$TMP/p1" "Phase 1 refreshes the git index"            'git update-index --refresh'

echo "single load"
JS_CALLS="$(grep -c '\$B js' "$TMP/p3" || true)"
if [ "$JS_CALLS" -eq 1 ]; then ok "Phase 3 reads every metric with one \$B js"; else no "Phase 3 reads every metric with one \$B js (found $JS_CALLS)"; fi
hasnt "$TMP/p3" "no separate perf call"                    '$B perf'
for k in nav fcp lcp resources scripts css summary; do
  if grep '\$B js' "$TMP/p3" | grep -qE "[{,]${k}[:,}]"; then ok "the one load returns $k"; else no "the one load returns $k"; fi
done
has "$TMP/p3" "navigation status is read"                  'responseStatus'
has "$TMP/p3" "non-2xx load fails the run"                 'not 2xx'

echo "repeat runs"
has "$TMP/p3" "five loads per page"                        '5 runs'
has "$TMP/p3" "per-metric median"                          'median'
has "$TMP/p3" "per-metric range"                           '[min,max]'

echo "baseline schema"
awk '/^```json$/ {f=1; next} f && /^```$/ {exit} f' "$TMP/p4" > "$TMP/baseline.json"
if python3 -I - "$TMP/baseline.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert isinstance(doc.get("runs"), int) and doc["runs"] == 5, "runs"
for page in doc["pages"].values():
    rng = page["range_ms"]
    for metric in ("ttfb_ms", "fcp_ms", "lcp_ms", "full_load_ms"):
        assert metric in page, metric
        lo, hi = rng[metric]
        assert lo <= page[metric] <= hi, metric
PY
then ok "baseline JSON carries runs and a range around each median"
else no "baseline JSON carries runs and a range around each median"
fi
has "$TMP/p4" "legacy baseline counts as one run"          'counts as 1 run'

echo "comparison"
has "$TMP/p5" "delta inside the spread is OK"              'inside the baseline range'
has "$TMP/p5" "one-run comparison is inconclusive"         'INCONCLUSIVE'
has "$SKILL"  "--quick is one run with no verdict"         'one run, no verdict'
has "$TMP/p5" "no-baseline rule"                           'No baseline'
has "$TMP/p5" "zero-baseline rule"                         'baseline value of 0'

echo "vet the number"
has "$TMP/vet" "verdict comes first"                       'VERDICT:'
for v in faster slower 'no difference' inconclusive; do
  has "$TMP/vet" "verdict word: $v"                        "$v"
done
has "$TMP/vet" "limiter comes from Phase 6"                'Phase 6'
has "$TMP/vet" "failed loads are counted"                  'failed or non-2xx'

echo "budget grade"
has "$TMP/p7" "FAIL at or over budget"                     'at or over budget = FAIL'
has "$TMP/p7" "WARNING at 90-100%"                         '90-100% of budget = WARNING'
has "$TMP/p7" "missing metric is N/A"                      'N/A'
has "$TMP/p7" "grade by share under budget"                'share of metrics under budget'

echo "report names"
has   "$TMP/p9" "reports use a UTC timestamp"              'date -u +%Y%m%dT%H%M%SZ'
hasnt "$SKILL"  "no bare-date report name"                 '{date}-benchmark'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
