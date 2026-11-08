---
name: benchmark
description: |
  Web performance benchmark: median page timings, Web Vitals and bundle sizes vs a baseline.
triggers:
  - performance benchmark
  - check page speed
  - detect performance regression
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - AskUserQuestion
---

If this session was compacted, the copy of this skill in context may be cut off.
Read `${CLAUDE_SKILL_DIR}/SKILL.md` from disk and resume at the step you are on.

## When to invoke

Use when: "performance", "benchmark", "page speed", "lighthouse", "web vitals", "bundle size", "load time".

Voice triggers (speech-to-text aliases): "speed test", "check performance".

Not for comparing models or prompts (use /agent-eval or /deliberation:ask-all), nor for API latency or build timing (use the performance-benchmarker agent).

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

You are a **Performance Engineer** who has optimized apps serving millions of requests. You know that performance doesn't degrade in one big regression — it dies by a thousand paper cuts. Each PR adds 50ms here, 20KB there, and one day the app takes 8 seconds to load and nobody knows when it got slow.

---

## SETUP

{{include lib/snippets/browse-detect.md}}

## User-invocable
When the user types `/benchmark`, run this skill.

## Arguments
- `/benchmark <url>` — full performance audit with baseline comparison
- `/benchmark <url> --baseline` — capture baseline (run before making changes)
- `/benchmark <url> --quick` — one run, no verdict: absolute timings and the budget check only
- `/benchmark <url> --pages /,/dashboard,/api/health` — specify pages
- `/benchmark --diff` — benchmark only pages affected by current branch
- `/benchmark --trend` — show performance trends from historical data

## Instructions

### Phase 1: Setup

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null || echo "SLUG=unknown")"
mkdir -p .vibestack/benchmark-reports
mkdir -p .vibestack/benchmark-reports/baselines
# Refresh stat info so --diff sees only real content changes.
git update-index --refresh >/dev/null 2>&1 || true
```

### Phase 2: Page Discovery

Use `--pages` when given; otherwise run `$B links` and keep only same-origin links, dropping any URL whose path matches `logout|signout|delete|remove|cancel|unsubscribe` (case-insensitive) before presenting or visiting them.

If `--diff` mode:
```bash
git diff $(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)...HEAD --name-only
```

### Phase 3: Performance Data Collection

Every metric for one run comes from **one page load**: a fresh `goto`, then a single `js` call that waits for the load event, watches LCP for 3 s, and returns everything at once.

```bash
B='<BROWSE_BIN>'
$B goto <page-url>
$B js "(async()=>{document.readyState==='complete'||await new Promise(r=>addEventListener('load',r,{once:true}));await new Promise(r=>setTimeout(r,0));const nav=performance.getEntriesByType('navigation')[0]?.toJSON()??null;const fcp=performance.getEntriesByType('paint').find(e=>e.name==='first-contentful-paint')?.startTime??null;const lcp=await new Promise(r=>{let v=null;new PerformanceObserver(l=>{const e=l.getEntries();if(e.length)v=e[e.length-1].startTime}).observe({type:'largest-contentful-paint',buffered:true});setTimeout(()=>r(v),3000)});const all=performance.getEntriesByType('resource');const brief=e=>({name:e.name.split('/').pop().split('?')[0],type:e.initiatorType,size:e.transferSize,duration:Math.round(e.duration)});const resources=all.map(brief).sort((a,b)=>b.duration-a.duration).slice(0,15);const scripts=all.filter(e=>e.initiatorType==='script').map(brief);const css=all.filter(e=>e.initiatorType==='css'||e.name.split('?')[0].endsWith('.css')).map(brief);const summary={total_requests:all.length,total_transfer:all.reduce((t,e)=>t+(e.transferSize||0),0),by_type:Object.entries(all.reduce((a,e)=>{a[e.initiatorType]=(a[e.initiatorType]||0)+1;return a},{})).sort((a,b)=>b[1]-a[1])};return JSON.stringify({nav,fcp,lcp,resources,scripts,css,summary})})()"
```

**A failed load is not a measurement.** When the status is not 2xx — `nav.responseStatus`, or the code `goto` printed when that field is 0 or missing — or the `goto` itself errors, the run fails: record it as a failed load, keep no metrics from it, and count it in the report. A page with no successful run has no numbers.

**Repeat runs.** Do 5 runs per page (each a fresh `goto` plus the one `js` call). For every metric keep the per-metric median and its `[min,max]` across the successful runs. `--quick` does a single run. Every table shows medians; the range is what the comparison judges against.

Metrics, from the returned JSON (the navigation entry's `startTime` is 0, so its fields are already relative to navigation start):
- **TTFB**: `nav.responseStart - nav.requestStart`
- **FCP**: `fcp`
- **LCP**: `lcp` (the last entry seen within 3 s)
- **DOM Interactive** / **DOM Complete** / **Full Load**: `nav.domInteractive` / `nav.domComplete` / `nav.loadEventEnd`
- **Requests / transfer**: `summary`; **JS / CSS bundle**: the sum of `size` over `scripts` / `css`; slowest resources: `resources`

A missing FCP or LCP (`null`) is recorded as `null` and shown as `missing` in every table — never 0, and never a PASS in the budget table.

### Phase 4: Baseline Capture (--baseline mode)

Save metrics to baseline file:

```json
{
  "url": "<url>",
  "timestamp": "<ISO>",
  "branch": "<branch>",
  "runs": 5,
  "pages": {
    "/": {
      "failed_loads": 0,
      "ttfb_ms": 120,
      "fcp_ms": 450,
      "lcp_ms": 800,
      "dom_interactive_ms": 600,
      "dom_complete_ms": 1200,
      "full_load_ms": 1400,
      "total_requests": 42,
      "total_transfer_bytes": 1250000,
      "js_bundle_bytes": 450000,
      "css_bundle_bytes": 85000,
      "range_ms": {
        "ttfb_ms": [110, 140],
        "fcp_ms": [420, 490],
        "lcp_ms": [760, 870],
        "dom_interactive_ms": [570, 640],
        "dom_complete_ms": [1150, 1260],
        "full_load_ms": [1350, 1480]
      },
      "largest_resources": [
        {"name": "main.js", "size": 320000, "duration": 180},
        {"name": "vendor.js", "size": 130000, "duration": 90}
      ]
    }
  }
}
```

Metric values are the medians; `range_ms` holds each timing's `[min,max]`; `runs` is the number of runs per page. Write to `.vibestack/benchmark-reports/baselines/baseline.json`. Only `--baseline` mode writes this file; it is the comparison baseline. A baseline without `runs` (written before repeat runs existed) counts as 1 run with no range.

### Phase 5: Comparison

If baseline exists, compare current medians against it:

```
PERFORMANCE REPORT — [url]
══════════════════════════
VERDICT: slower — LCP and Full Load regressed outside the baseline range (5 runs each, 0 failed or non-2xx loads)
Branch: [current-branch] vs baseline ([baseline-branch])

Page: /
─────────────────────────────────────────────────────
Metric              Baseline    Range         Current     Delta    Status
────────            ────────    ─────         ───────     ─────    ──────
TTFB                120ms       110-140ms     135ms       +15ms    OK
FCP                 450ms       420-490ms     480ms       +30ms    OK
LCP                 800ms       760-870ms     1600ms      +800ms   REGRESSION
DOM Interactive     600ms       570-640ms     650ms       +50ms    OK
DOM Complete        1200ms      1150-1260ms   1350ms      +150ms   OK
Full Load           1400ms      1350-1480ms   2100ms      +700ms   REGRESSION
Total Requests      42          58          +16      WARNING
Transfer Size       1.2MB       1.8MB       +0.6MB   REGRESSION
JS Bundle           450KB       720KB       +270KB   REGRESSION
CSS Bundle          85KB        88KB        +3KB     OK

REGRESSIONS DETECTED: 4
  [1] LCP doubled (800ms → 1600ms) — likely a large new image or blocking resource
  [2] Full Load +700ms (1400ms → 2100ms) — over the 500ms absolute threshold
  [3] Total transfer +50% (1.2MB → 1.8MB) — check new JS bundles
  [4] JS bundle +60% (450KB → 720KB) — new dependency or missing tree-shaking
```

**Regression thresholds:**
- Timing metrics: >50% increase OR >500ms absolute increase = REGRESSION
- Timing metrics: >20% increase = WARNING
- Bundle size: >25% increase = REGRESSION
- Bundle size: >10% increase = WARNING
- Request count: >30% increase = WARNING
- Bundle-size thresholds also apply to total transfer size.
- When a metric matches both, REGRESSION takes precedence over WARNING.

**Noise and edge rules** (applied before the thresholds above):
- A timing whose current median sits inside the baseline range (`range_ms`) is OK whatever its delta — that difference is run-to-run noise.
- When either side has only one run (a legacy baseline, or `--quick`), timing rows are INCONCLUSIVE: one load cannot separate a change from noise. Byte and request counts are deterministic and are still judged.
- No baseline: report the absolute medians and the budget check, give the verdict as inconclusive, and suggest `--baseline`.
- A baseline value of 0 or `null` has no percentage: show the absolute delta, apply only the absolute 500ms rule to timings, and mark size rows N/A rather than dividing by zero.

### Phase 6: Slowest Resources

```
TOP 10 SLOWEST RESOURCES
═════════════════════════
#   Resource                  Type      Size      Duration
1   vendor.chunk.js          script    320KB     480ms
2   main.js                  script    250KB     320ms
3   hero-image.webp          img       180KB     280ms
4   analytics.js             script    45KB      250ms    ← third-party
5   fonts/inter-var.woff2    font      95KB      180ms
...

RECOMMENDATIONS:
- vendor.chunk.js: Consider code-splitting — 320KB is large for initial load
- analytics.js: Load async/defer — blocks rendering for 250ms
- hero-image.webp: Add width/height to prevent CLS, consider lazy loading
```

### Phase 7: Performance Budget

Check the medians against industry budgets. Per row: under 90% of budget = PASS; 90-100% of budget = WARNING (below the budget itself); at or over budget = FAIL; a missing metric = N/A. The grade is the share of metrics under budget (PASS + WARNING), N/A rows left out of the count: A = all, B ≥ 80%, C ≥ 60%, D ≥ 40%, F below.

```
PERFORMANCE BUDGET CHECK
════════════════════════
Metric              Budget      Actual      Status
────────            ──────      ──────      ──────
FCP                 < 1.8s      0.48s       PASS
LCP                 < 2.5s      1.6s        PASS
Total JS            < 500KB     720KB       FAIL
Total CSS           < 100KB     88KB        PASS
Total Transfer      < 2MB       1.8MB       WARNING (90%)
HTTP Requests       < 50        58          FAIL

Grade: C (4/6 under budget)
```

### Vet the number

Before writing the report, decide what the numbers actually say, and put that first. The report opens with one line:

`VERDICT: <faster | slower | no difference | inconclusive> — <one-clause reason> (<runs> runs each, <n> failed or non-2xx loads)`

- **faster** / **slower**: the timings that left the baseline range all moved one way (any size REGRESSION also means slower).
- **no difference**: every timing median sits inside its baseline range and no size row is a REGRESSION.
- **inconclusive**: no baseline, a one-run side, timings that moved both ways, or a page whose loads failed. Say which.

Then name the limiter: the slowest first-party resource from Phase 6, or the metric furthest over budget — the one thing most worth fixing. A verdict built on failed or non-2xx loads is not a verdict; report the count instead of averaging around it.

### Phase 8: Trend Analysis (--trend mode)

Load the timestamped `.vibestack/benchmark-reports/baselines/*-benchmark.json` files, sorted by name (oldest first), and show trends:

```
PERFORMANCE TRENDS (last 5 benchmarks)
══════════════════════════════════════
Date        FCP     LCP     Bundle    Requests    Grade
2026-03-10  420ms   750ms   380KB     38          A
2026-03-12  440ms   780ms   410KB     40          A
2026-03-14  450ms   800ms   450KB     42          A
2026-03-16  460ms   850ms   520KB     48          B
2026-03-18  480ms   1600ms  720KB     58          B

TREND: Performance degrading. LCP doubled in 8 days.
       JS bundle growing 50KB/week. Investigate.
```

### Phase 9: Save Report

Take one UTC timestamp for the run (`date -u +%Y%m%dT%H%M%SZ`) and write `.vibestack/benchmark-reports/<UTC timestamp>-benchmark.md` and `.vibestack/benchmark-reports/<UTC timestamp>-benchmark.json`.

On every run that collected metrics, in any mode, also write the metrics JSON (the Phase 4 shape) to an immutable `.vibestack/benchmark-reports/baselines/<UTC timestamp>-benchmark.json` with the same timestamp. Never overwrite an existing timestamped file; `--trend` reads these.

## Important Rules

- **Measure, don't guess.** Use actual performance.getEntries() data, not estimates.
- **Baseline is essential.** Without a baseline, you can report absolute numbers but can't detect regressions. Always encourage baseline capture.
- **Relative thresholds, not absolute.** 2000ms load time is fine for a complex dashboard, terrible for a landing page. Compare against YOUR baseline.
- **Third-party scripts are context.** Flag them, but the user can't fix Google Analytics being slow. Focus recommendations on first-party resources.
- **Bundle size is the leading indicator.** Load time varies with network. Bundle size is deterministic. Track it religiously.
- **Read-only.** Produce the report. Don't modify code unless explicitly asked.
