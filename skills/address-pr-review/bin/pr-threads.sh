#!/usr/bin/env bash
# pr-threads.sh — list the unresolved review threads on the current branch's PR.
#
# Prints a JSON array. Each element:
#   {id, isResolved, isOutdated, path, line, startLine,
#    comments: [{author, body, url}]}
#
# Exit 0 with the array (possibly empty) on success.
# Exit 2 when the branch has no PR, when gh cannot see the repo, or when a page
# of threads could not be fetched.
#
# Threads are paged through to the end, so the array is the complete list — a PR
# with more than 100 threads is not silently cut to the first page. A single
# thread still carries at most 100 comments; when a thread has more, the script
# says so on stderr rather than letting the caller read a short comment list as
# a complete one.
set -euo pipefail

# Guard against a cursor that never advances. 50 pages is 5000 threads.
MAX_PAGES="${PR_THREADS_MAX_PAGES:-50}"

if ! command -v gh >/dev/null 2>&1; then
  echo "pr-threads: gh CLI not found — install it and run 'gh auth login'" >&2
  exit 2
fi

OWNER=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null) || {
  echo "pr-threads: not inside a GitHub repository gh can see" >&2
  exit 2
}
NAME=$(gh repo view --json name --jq '.name' 2>/dev/null) || {
  echo "pr-threads: not inside a GitHub repository gh can see" >&2
  exit 2
}

BRANCH=$(git branch --show-current 2>/dev/null || true)
PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null) || {
  echo "pr-threads: no pull request found for branch '${BRANCH:-?}' — open one first (/ship)" >&2
  exit 2
}

QUERY='query($owner:String!, $name:String!, $number:Int!, $after:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100, after:$after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line startLine
          comments(first:100) {
            pageInfo { hasNextPage }
            nodes { author { login } body url }
          }
        }
      }
    }
  }
}'

# One pass over a page emits three kinds of line, told apart by their first
# character. "#cursor:" carries the cursor for the next page, empty when this
# was the last one. "#comments-truncated:" names a thread whose comment list was
# cut at 100. Every other line is one unresolved thread as a compact JSON
# object; an object always starts with "{", so a marker can never be read as
# data, and a body containing newlines stays on one line because jq escapes them.
FILTER='.data.repository.pullRequest.reviewThreads
  | ("#cursor:" + (if .pageInfo.hasNextPage then .pageInfo.endCursor else "" end)),
    (.nodes[] | select(.comments.pageInfo.hasNextPage) | "#comments-truncated:" + .id),
    (.nodes[]
     | select(.isResolved == false)
     | {id, isResolved, isOutdated, path, line, startLine,
        comments: [.comments.nodes[] | {author: .author.login, body, url}]})'

CURSOR=""
PAGE_NO=0
THREADS=""

while :; do
  PAGE_NO=$((PAGE_NO + 1))
  if [ "$PAGE_NO" -gt "$MAX_PAGES" ]; then
    echo "pr-threads: stopped after $MAX_PAGES pages — the list is incomplete, so nothing is printed" >&2
    exit 2
  fi

  ARGS=(-f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR_NUMBER")
  # The first page passes no cursor at all; $after is nullable, and GraphQL
  # reads an omitted nullable variable as null.
  if [ -n "$CURSOR" ]; then
    ARGS+=(-f after="$CURSOR")
  fi

  PAGE=$(gh api graphql "${ARGS[@]}" --jq "$FILTER") || {
    echo "pr-threads: could not fetch review thread page $PAGE_NO for $OWNER/$NAME#$PR_NUMBER" >&2
    exit 2
  }

  NEXT=""
  while IFS= read -r LINE; do
    case "$LINE" in
      '') ;;
      '#cursor:'*) NEXT="${LINE#\#cursor:}" ;;
      '#comments-truncated:'*)
        echo "pr-threads: thread ${LINE#\#comments-truncated:} has more than 100 comments — only the first 100 are listed" >&2
        ;;
      *) THREADS="${THREADS}${LINE}"$'\n' ;;
    esac
  done <<< "$PAGE"

  CURSOR="$NEXT"
  [ -n "$CURSOR" ] || break
done

if [ -z "$THREADS" ]; then
  printf '[]\n'
else
  printf '%s' "$THREADS" \
    | awk 'NR == 1 { printf "[" } NR > 1 { printf "," } { printf "%s", $0 } END { print "]" }'
fi
