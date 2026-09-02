#!/usr/bin/env bash
# pr-ci-failures.sh — show why CI is red on the current branch's PR.
#
# Exit 0 and print one status line when nothing failed.
# Exit 1 and print a trimmed log excerpt per failing check otherwise.
# Exit 2 when the branch has no PR, or when gh could not answer at all.
#
# The excerpt starts at the first line matching FAIL|ERROR|error: and stops
# at the job's summary line ("Process completed with exit code" or "##[error]"),
# capped at PR_CI_MAX_LINES (default 80) so a chatty job does not flood the context.
# A job whose log carries no such line gets its last TAIL_LINES lines instead,
# so the excerpt is never empty.
set -euo pipefail

MAX_LINES="${PR_CI_MAX_LINES:-80}"
TAIL_LINES=20

if ! command -v gh >/dev/null 2>&1; then
  echo "pr-ci-failures: gh CLI not found — install it and run 'gh auth login'" >&2
  exit 2
fi

BRANCH=$(git branch --show-current 2>/dev/null || true)
if ! gh pr view --json number --jq '.number' >/dev/null 2>&1; then
  echo "pr-ci-failures: no pull request found for branch '${BRANCH:-?}' — open one first (/ship)" >&2
  exit 2
fi

# One request for the whole check list; everything below is derived from it.
#
# The exit code alone cannot tell a red build from a broken request: gh exits 1
# when a check failed and 8 while checks are pending, but also 1 for an auth,
# network, or API error. So keep stdout and stderr apart and decide on the pair.
# Rows on stdout mean the request worked, whatever the exit code. No rows plus a
# non-zero exit means gh could not answer, and the only such case that is not an
# error is a PR that has no checks at all — gh says so in words. Anything else
# is reported as a failure rather than silently read as "green".
#
# Match on `bucket`, not `state`. gh sets state to the run's status while a check
# is incomplete (WAITING, REQUESTED, QUEUED) and to its conclusion only once it
# completes, so a state allowlist misses cases in both directions —
# ACTION_REQUIRED is a failure, WAITING is pending. bucket collapses all of them
# into pass/fail/pending/skipping/cancel.
CHECKS_ERR=$(mktemp "${TMPDIR:-/tmp}/pr-ci-failures.XXXXXX")
trap 'rm -f "$CHECKS_ERR"' EXIT

CHECKS_STATUS=0
CHECKS=$(gh pr checks --json name,bucket,link \
  --jq '.[] | [.bucket, .name, .link] | @tsv' 2>"$CHECKS_ERR") || CHECKS_STATUS=$?

if [ -z "$CHECKS" ]; then
  if [ "$CHECKS_STATUS" -eq 0 ] || grep -qi 'no checks reported' "$CHECKS_ERR"; then
    echo "This PR has no checks yet."
    exit 0
  fi
  echo "pr-ci-failures: 'gh pr checks' failed (exit $CHECKS_STATUS) and returned no check list" >&2
  sed 's/^/  /' "$CHECKS_ERR" >&2
  exit 2
fi

count_bucket() {
  printf '%s\n' "$CHECKS" | awk -F'\t' -v want="$1" '$1 == want { n++ } END { print n + 0 }'
}

FAILING=$(printf '%s\n' "$CHECKS" | awk -F'\t' '$1 == "fail" { print $2 "\t" $3 }')
PENDING=$(count_bucket pending)
CANCELLED=$(count_bucket cancel)

# A cancelled check ran and was stopped. It is neither a pass nor a code
# failure, so it gets its own line and never rolls into "All checks passed."
if [ "$CANCELLED" -gt 0 ]; then
  echo "CANCELLED CHECKS: $CANCELLED (a cancelled check is not a pass)"
  printf '%s\n' "$CHECKS" | awk -F'\t' '$1 == "cancel" { print "    " $2 }'
fi

if [ -z "$FAILING" ]; then
  if [ "$CANCELLED" -gt 0 ] && [ "$PENDING" -gt 0 ]; then
    echo "No failing checks; $CANCELLED cancelled, $PENDING still pending."
  elif [ "$CANCELLED" -gt 0 ]; then
    echo "No failing checks; $CANCELLED cancelled."
  elif [ "$PENDING" -gt 0 ]; then
    echo "No failing checks; $PENDING still pending."
  else
    echo "All checks passed."
  fi
  exit 0
fi

FAIL_COUNT=$(printf '%s\n' "$FAILING" | grep -c .)
echo "FAILING CHECKS: $FAIL_COUNT"
printf '%s\n' "$FAILING" | while IFS=$'\t' read -r NAME LINK; do
  [ -n "$NAME" ] || continue
  echo
  echo "=== $NAME"
  echo "    $LINK"
  # Actions job links look like .../actions/runs/<run>/job/<job>[?...]. Stop the
  # leading match at the query string so a job id repeated in a query parameter
  # cannot override the one in the path.
  JOB_ID=$(printf '%s' "$LINK" | sed -nE 's#^[^?]*/actions/runs/[0-9]+/job/([0-9]+).*#\1#p')
  if [ -z "$JOB_ID" ]; then
    echo "    (no Actions job id in link — open the link for details)"
    continue
  fi
  LOG=$(gh run view --job "$JOB_ID" --log 2>/dev/null || true)
  if [ -z "$LOG" ]; then
    echo "    (log not available yet — the job may still be uploading)"
    continue
  fi
  # Strip the "job<TAB>step<TAB>timestamp " prefix gh puts on each log line.
  #
  # awk exits as soon as it has the excerpt, so on a log larger than one pipe
  # buffer sed and printf are still writing and take SIGPIPE. Under pipefail that
  # is exit 141 for the whole pipeline, which would abort the `while` subshell and
  # drop every remaining failing check. The excerpt is already printed by then, so
  # discard the status.
  printf '%s\n' "$LOG" \
    | sed -E 's/^[^	]*	[^	]*	[0-9T:.Z-]+ ?//' \
    | awk -v max="$MAX_LINES" -v tail="$TAIL_LINES" '
        { total++ }
        !on && /FAIL|ERROR|error:/ { on = 1 }
        on { print; n++ }
        !on { buf[total % tail] = $0 }
        on && (/Process completed with exit code/ || /##\[error\]/) { stop = 1; exit }
        n >= max { print "... (excerpt truncated at " max " lines)"; stop = 1; exit }
        END {
          if (stop || on) exit
          print "    (no FAIL/ERROR line found — showing the last " tail " lines)"
          start = (total > tail) ? total - tail + 1 : 1
          for (i = start; i <= total; i++) print buf[i % tail]
        }
      ' || true
done
exit 1
