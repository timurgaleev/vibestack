**Create this run's report directory.** Every run writes into its own
`run-<UTC>` directory under the output dir, and the prior baseline is resolved
before anything is written:

```bash
setopt +o nomatch 2>/dev/null || true  # zsh compat
QA_ROOT='<output dir, default .vibestack/qa-reports>'
BASELINE_ARG='<--regression path, or empty>'
PRIOR=""
if [ -n "$BASELINE_ARG" ]; then
  if [ -f "$BASELINE_ARG" ]; then
    PRIOR="$BASELINE_ARG"
  else
    echo "BASELINE_MISSING: $BASELINE_ARG"
  fi
else
  PRIOR="$(ls -1d "$QA_ROOT"/run-*/baseline.json 2>/dev/null | sort | tail -1)"
fi
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
REPORT_DIR="$QA_ROOT/run-$RUN_ID"
[ -e "$REPORT_DIR" ] && REPORT_DIR="$REPORT_DIR-$$"
mkdir -p "$REPORT_DIR/screenshots"
if [ -n "$PRIOR" ]; then
  cp "$PRIOR" "$REPORT_DIR/prior-baseline.json"
  echo "PRIOR_BASELINE: $REPORT_DIR/prior-baseline.json (copied from $PRIOR)"
else
  echo "PRIOR_BASELINE: none"
fi
echo "REPORT_DIR: $REPORT_DIR"
```

Replace `<output dir, ...>` with the user's output dir, or
`.vibestack/qa-reports` when none was given. Replace `<--regression path, ...>`
with the path the user passed to `--regression`, or leave it empty: an empty
value picks the newest earlier run's `baseline.json` under the output dir.

- `PRIOR_BASELINE: none` — this is the first run under that output dir. Skip
  the regression comparison and say so in the report.
- `BASELINE_MISSING` — the `--regression` path does not exist. The run still
  happens; only the comparison is skipped, and the report names the missing
  path.

Never overwrite an earlier run's report, baseline or screenshots: this run
writes only inside its own `REPORT_DIR`, and the regression comparison reads
`$REPORT_DIR/prior-baseline.json`, never the `baseline.json` this run writes.

Later blocks that write into the run start with `REPORT_DIR='<REPORT_DIR>'`:
replace `<REPORT_DIR>` with the path printed on the `REPORT_DIR:` line.
