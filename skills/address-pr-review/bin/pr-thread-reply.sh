#!/usr/bin/env bash
# pr-thread-reply.sh <thread_id> <body> [--resolve]
#
# Reply to one review thread on the current PR; with --resolve, also mark
# the thread resolved. Prints the URL of the new comment.
#
# A thread id is a global node id, so it names a thread on any PR in any repo.
# Before mutating anything the script resolves the current branch's PR and
# checks that the thread belongs to it — a stale id left over from an earlier
# round would otherwise post a reply on a different PR without a word.
#
# Exit 0 on success, 1 on bad arguments or API failure.
# Exit 2 when the branch has no PR, or when gh cannot see the repo.
set -euo pipefail

usage() {
  echo "usage: pr-thread-reply.sh <thread_id> <body> [--resolve]" >&2
  exit 1
}

[ $# -ge 2 ] || usage
THREAD_ID="$1"
BODY="$2"
RESOLVE=0
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --resolve) RESOLVE=1 ;;
    *) usage ;;
  esac
  shift
done

[ -n "$THREAD_ID" ] || usage
[ -n "$BODY" ] || { echo "pr-thread-reply: empty body" >&2; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
  echo "pr-thread-reply: gh CLI not found — install it and run 'gh auth login'" >&2
  exit 1
fi

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
  echo "pr-thread-reply: not inside a GitHub repository gh can see" >&2
  exit 2
}

BRANCH=$(git branch --show-current 2>/dev/null || true)
PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null) || {
  echo "pr-thread-reply: no pull request found for branch '${BRANCH:-?}' — open one first (/ship)" >&2
  exit 2
}

OWNER_QUERY='query($threadId:ID!) {
  node(id:$threadId) {
    ... on PullRequestReviewThread {
      pullRequest { number repository { nameWithOwner } }
    }
  }
}'

# Empty when the id is not a review thread, or when the token cannot see it.
THREAD_PR=$(gh api graphql \
  -f query="$OWNER_QUERY" \
  -f threadId="$THREAD_ID" \
  --jq '.data.node.pullRequest
        | .repository.nameWithOwner + "#" + (.number | tostring)' 2>/dev/null || true)

if [ -z "$THREAD_PR" ]; then
  echo "pr-thread-reply: '$THREAD_ID' is not a review thread this token can read" >&2
  exit 1
fi
if [ "$THREAD_PR" != "$REPO#$PR_NUMBER" ]; then
  echo "pr-thread-reply: thread belongs to $THREAD_PR, but this branch's PR is $REPO#$PR_NUMBER" >&2
  echo "pr-thread-reply: re-run pr-threads.sh to get ids for the current PR" >&2
  exit 1
fi

REPLY_MUTATION='mutation($threadId:ID!, $body:String!) {
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}) {
    comment { url }
  }
}'

# -f passes strings verbatim; -F would try to interpret @file and numbers.
URL=$(gh api graphql \
  -f query="$REPLY_MUTATION" \
  -f threadId="$THREAD_ID" \
  -f body="$BODY" \
  --jq '.data.addPullRequestReviewThreadReply.comment.url')

if [ "$RESOLVE" -eq 1 ]; then
  RESOLVE_MUTATION='mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { isResolved }
    }
  }'
  RESOLVED=$(gh api graphql \
    -f query="$RESOLVE_MUTATION" \
    -f threadId="$THREAD_ID" \
    --jq '.data.resolveReviewThread.thread.isResolved')
  if [ "$RESOLVED" != "true" ]; then
    echo "pr-thread-reply: reply posted but thread did not resolve" >&2
    echo "$URL"
    exit 1
  fi
fi

echo "$URL"
