#!/usr/bin/env bash
# pr-threads.sh — list the unresolved review threads on the current branch's PR.
#
# Prints a JSON array. Each element:
#   {id, isResolved, isOutdated, path, line, startLine,
#    comments: [{author, body, url}]}
#
# Exit 0 with the array (possibly empty) on success.
# Exit 2 when the branch has no PR, or when gh cannot see the repo.
#
# A page holds at most 100 threads and 100 comments per thread. When either cap
# is hit the tail is missing from the array, so the script says so on stderr
# rather than letting the caller read a short list as a complete one.
set -euo pipefail

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

QUERY='query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100) {
        nodes {
          id isResolved isOutdated path line startLine
          comments(first:100) { nodes { author { login } body url } }
        }
      }
    }
  }
}'

PAGE_QUERY='query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100) {
        pageInfo { hasNextPage }
        nodes { id comments(first:100) { pageInfo { hasNextPage } } }
      }
    }
  }
}'

TRUNCATED=$(gh api graphql \
  -f query="$PAGE_QUERY" \
  -f owner="$OWNER" \
  -f name="$NAME" \
  -F number="$PR_NUMBER" \
  --jq '.data.repository.pullRequest.reviewThreads
        | (if .pageInfo.hasNextPage then "threads" else empty end),
          (.nodes[] | select(.comments.pageInfo.hasNextPage) | "comments:" + .id)' 2>/dev/null || true)

if [ -n "$TRUNCATED" ]; then
  printf '%s\n' "$TRUNCATED" | while IFS= read -r ITEM; do
    case "$ITEM" in
      threads)
        echo "pr-threads: this PR has more than 100 review threads — only the first 100 are listed" >&2
        ;;
      comments:*)
        echo "pr-threads: thread ${ITEM#comments:} has more than 100 comments — only the first 100 are listed" >&2
        ;;
    esac
  done
fi

gh api graphql \
  -f query="$QUERY" \
  -f owner="$OWNER" \
  -f name="$NAME" \
  -F number="$PR_NUMBER" \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved == false)
         | {id, isResolved, isOutdated, path, line, startLine,
            comments: [.comments.nodes[] | {author: .author.login, body, url}]}]'
